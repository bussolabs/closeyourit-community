# frozen_string_literal: true

require "net/http"
require "uri"

module Seo
  # Scarica UNA risorsa e ne ritorna l'esito, senza toccare il database e senza giudicare niente.
  # È l'unico punto del dominio che apre una connessione: tutto ciò che riguarda "come si bussa a un
  # sito che non è nostro" vive qui e si legge in un colpo solo.
  #
  # SICUREZZA (SSRF): l'indirizzo arriva da chi compila il form, quindi prima di aprire la
  # connessione si risolve l'host UNA volta con NetworkGuard e si PINNA l'IP validato su
  # `Net::HTTP#ipaddr=` — esattamente come Uptime::Ping. Ri-risolvere al connect riaprirebbe il
  # buco fra la validazione e la connessione (DNS rebinding), e va rifatto a ogni salto della
  # catena di redirect: un 302 verso `http://169.254.169.254/` è il modo classico per farsi
  # raccontare le credenziali della macchina.
  #
  # GENTILEZZA: stiamo visitando il sito di qualcun altro. Corpo limitato, timeout corti,
  # user-agent che dice chi siamo e dove chiedere spiegazioni.
  class Fetch < ApplicationService
    # Quello che il proprietario del sito legge nei suoi log. Un crawler anonimo è un crawler che
    # verrà bloccato, e giustamente.
    USER_AGENT = "CloseYourItBot/1.0 (+https://www.closeyour.it/bot)"

    MAX_REDIRECTS = 5
    # Oltre questo non è più una pagina: è un file. Si tronca e si continua — il SEO sta nei primi
    # kilobyte, e scaricare 50 MB per contare gli h1 sarebbe solo un modo di occupare la coda.
    MAX_BODY_BYTES = 2_000_000
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    # Tetto sull'INTERA lettura, salti compresi (CYRA-1122). I due qui sopra valgono per una singola
    # attesa, e da soli non bastano: un sito che manda un byte ogni due secondi non ne fa scadere
    # nessuno e tiene occupata la corsia per ore. Ogni attesa — risoluzione, apertura, invio, ogni
    # pezzo del corpo — usa al più quello che resta di questi secondi.
    TOTAL_TIMEOUT = 30

    # Interrompe la lettura del corpo al tetto. È un'eccezione e non un `break` per due ragioni, e
    # nessuna delle due è stilistica: il blocco di `read_body` viene invocato di rimbalzo (un
    # `break` da lì solleverebbe `LocalJumpError`), e soprattutto solo un'eccezione che ESCE da
    # `Net::HTTP#request` fa chiudere il socket. Uscendo in modo ordinato, `Net::HTTP` finirebbe di
    # scaricare da sé il corpo rimasto per completare la risposta — cioè proprio i megabyte che qui
    # si sta rifiutando di leggere (CYRA-807).
    BudgetReached = Class.new(StandardError)
    # Il tempo totale è finito. Eccezione per la stessa ragione di BudgetReached: deve uscire da
    # `Net::HTTP#request` perché il socket venga chiuso invece di essere svuotato.
    DeadlineReached = Class.new(StandardError)

    Result = Data.define(:url, :final_url, :status_code, :redirect_chain, :body, :truncated,
                         :content_type, :response_time_ms, :error) do
      def initialize(url:, final_url: nil, status_code: nil, redirect_chain: [], body: nil,
                     truncated: false, content_type: nil, response_time_ms: nil, error: nil)
        super
      end

      def ok? = status_code == 200 && error.nil?
      def html? = content_type.to_s.include?("html")
      def redirected? = redirect_chain.any?
      def blocked? = error == "blocked"
      # Il corpo è arrivato fin dove si è voluto leggere, non fin dove finiva: quello che sta a
      # valle deve poter dire «pagina incompleta» invece di scambiare il taglio per il documento.
      def truncated? = truncated
    end

    # `budget`: secondi per l'intera lettura. Il giro passa il minore fra TOTAL_TIMEOUT e quanto
    # resta a lui (Seo::Crawl), così nemmeno l'ultima pagina sfora la scadenza del giro.
    def initialize(url:, timeout: READ_TIMEOUT, budget: TOTAL_TIMEOUT)
      @url = url.to_s
      @timeout = timeout
      @budget = budget
    end

    def call
      @deadline = clock + @budget
      uri = parse(@url)
      return failure("invalid_url") if uri.nil?

      follow(uri, [])
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, DeadlineReached
      failure("timeout")
    rescue StandardError => e
      failure(e.class.name.demodulize.underscore)
    end

    private

    def follow(uri, chain)
      return failure("too_many_redirects", chain) if chain.size > MAX_REDIRECTS

      # Ogni salto è una URL nuova, quindi una validazione nuova: la catena è dato del sito remoto.
      address = resolve(uri.host)
      return failure("blocked", chain) if address.nil?

      started = clock
      response, body, truncated = perform(uri, address)
      elapsed = ((clock - started) * 1000).round

      location = redirect_target(uri, response)
      return follow(location, chain + [ uri.to_s ]) if location

      log_truncation(uri) if truncated

      Result.new(url: @url, final_url: uri.to_s, status_code: response.code.to_i,
                 redirect_chain: chain, body: decode(body), truncated: truncated,
                 content_type: response["content-type"], response_time_ms: elapsed)
    end

    # Apre la connessione e legge il corpo A PEZZI, fermandosi al tetto. Senza blocco `Net::HTTP`
    # porterebbe in memoria l'intera risposta PRIMA che il tetto possa applicarsi: il limite
    # dichiarato non proteggerebbe niente, e una sola pagina da mezzo gigabyte basterebbe a far
    # finire la memoria al processo che esegue i controlli (CYRA-807).
    #
    # Il tetto vale sui byte DECOMPRESSI, che sono quelli che occupano memoria: `Net::HTTP` scompatta
    # anche in streaming, quindi i pezzi arrivano qui già distesi e una risposta compressa non compra
    # mille volte il budget.
    def perform(uri, address)
      http = connection(uri, address)
      response = nil
      body = String.new(encoding: Encoding::BINARY)
      truncated = false

      begin
        http.start do
          guard_socket(http)
          # Aprire la connessione ha consumato tempo: invio e attesa della risposta partono dal residuo.
          tighten(http)
          http.request(build_request(uri)) do |res|
            response = res
            # Il corpo di un 3xx non lo legge nessuno: si salta il salto senza scaricarlo.
            raise BudgetReached if res.is_a?(Net::HTTPRedirection)

            res.read_body do |chunk|
              room = MAX_BODY_BYTES - body.bytesize
              # `>=` e non `>`: al tetto si smette, anche quando il pezzo lo riempie esatto. Con `>`
              # si resterebbe in attesa del pezzo successivo per sapere se ce n'è ancora, e su una
              # risposta che promette più di quanto manda quell'attesa finisce nel read timeout —
              # cioè si butterebbe via il corpo già raccolto proprio dopo aver raggiunto il limite.
              # Il prezzo è dichiarare tagliato un corpo che finiva giusto lì: un dubbio scritto
              # costa meno di una pagina persa.
              if chunk.bytesize >= room
                body << chunk.byteslice(0, room)
                truncated = true
                raise BudgetReached
              end

              body << chunk
            end
          end
        end
      rescue BudgetReached
        nil # letto quanto basta: il resto della risposta resta dov'è
      end

      [ response, body, truncated ]
    end

    # `open_timeout` copre in Net::HTTP sia la connessione TCP sia, a parte, la stretta di mano TLS:
    # su https il residuo si divide fra le due, così l'apertura intera non lo supera.
    def connection(uri, address)
      http = Net::HTTP.new(uri.host, uri.port)
      http.ipaddr = address # IP validato pinnato; Host header, SNI e verifica del certificato restano sull'host
      http.use_ssl = uri.scheme == "https"
      opening = http.use_ssl? ? remaining / 2 : remaining
      http.open_timeout = [ OPEN_TIMEOUT, opening ].min
      # Dopo un read timeout `Net::HTTP` ripeterebbe la GET da capo su un socket nuovo: un secondo
      # giro di attese fuori dal conto. Lo scaduto resta scaduto (CYRA-1122).
      http.max_retries = 0
      tighten(http)
      http
    end

    # Il tempo residuo vale per OGNI lettura dal socket, non solo per i pezzi del corpo: riga di
    # stato, header e cornice dei pezzi chunked `Net::HTTP` li legge prima di chiamare qualunque
    # nostro blocco, e un sito che li manda un byte alla volta rinnoverebbe il read timeout
    # all'infinito. Tutte quelle letture passano da `Net::BufferedIO#rbuf_fill`: lì si accorcia
    # l'attesa e, a tempo finito, si interrompe (CYRA-1122). Il socket è per connessione, quindi la
    # modifica non tocca nessun altro.
    def guard_socket(http)
      socket = http.instance_variable_get(:@socket)
      return unless socket.is_a?(Net::BufferedIO) # con WebMock attivo il socket è finto

      socket.extend(DeadlineSocket)
      socket.remaining = method(:remaining)
    end

    module DeadlineSocket
      attr_writer :remaining

      private

      def rbuf_fill
        self.read_timeout = [ read_timeout, @remaining.call ].min
        super
      end
    end

    # Ogni attesa sul socket dura al più quanto resta della lettura, e a tempo finito la lettura si
    # interrompe (CYRA-1122).
    def tighten(http)
      left = remaining
      http.read_timeout = [ @timeout, left ].min
      http.write_timeout = left
    end

    # La risoluzione si ASPETTA al più per il residuo, non si interrompe: un `Thread#raise` o un
    # `Timeout.timeout` nel mezzo di Resolv può lasciare un socket aperto. Abbandonata, finisce da sé
    # entro le attese fisse di NetworkGuard (CYRA-1122). Un host che non risolve perché il tempo è
    # finito durante i tentativi è un tempo scaduto, non un indirizzo bloccato.
    def resolve(host)
      left = remaining
      guard = NetworkGuard # risolto qui: il thread non deve caricare costanti per conto suo
      lookup = Thread.new do
        Thread.current.report_on_exception = false
        guard.resolved_public_address(host, timeout: left)
      end
      raise DeadlineReached if lookup.join(left).nil?

      address = lookup.value
      raise DeadlineReached if address.nil? && expired?

      address
    end

    # Secondi rimasti alla lettura; a tempo finito la interrompe.
    def remaining
      left = @deadline - clock
      raise DeadlineReached unless left.positive?

      left
    end

    def expired? = clock >= @deadline

    def build_request(uri)
      request = Net::HTTP::Get.new(uri.request_uri)
      request["User-Agent"] = USER_AGENT
      request["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
      request
    end

    # I pezzi arrivano binari e si concatenano binari: mescolarli a una stringa UTF-8 solleverebbe
    # `Encoding::CompatibilityError` a metà lettura. L'etichetta si mette una volta sola, alla fine,
    # e `scrub` ripara il carattere che il taglio può aver spezzato a metà.
    def decode(body)
      return nil if body.blank?

      String.new(body, encoding: Encoding::UTF_8).scrub
    end

    # Host e percorso, MAI la query: le URL da visitare arrivano dai link e dalla sitemap di un sito
    # che non è nostro, e una di quelle può portarsi dietro un token in chiaro. Per ritrovare la
    # pagina pesante il percorso basta.
    def log_truncation(uri)
      Rails.logger.warn("[seo] corpo troncato a #{MAX_BODY_BYTES} byte: #{uri.host}#{uri.path}")
    end

    def redirect_target(uri, response)
      return nil unless response.is_a?(Net::HTTPRedirection)

      location = response["location"]
      return nil if location.blank?

      # Location relativa è legale (RFC 7231): si risolve contro la URL corrente.
      parse(URI.join(uri, location).to_s)
    rescue URI::Error
      nil
    end

    def parse(raw)
      uri = URI.parse(raw)
      return nil unless uri.is_a?(URI::HTTP) && uri.host.present?

      uri
    rescue URI::InvalidURIError
      nil
    end

    def failure(error, chain = [])
      Result.new(url: @url, redirect_chain: chain, error:)
    end

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
