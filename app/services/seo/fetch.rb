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

    # Interrompe la lettura del corpo al tetto. È un'eccezione e non un `break` per due ragioni, e
    # nessuna delle due è stilistica: il blocco di `read_body` viene invocato di rimbalzo (un
    # `break` da lì solleverebbe `LocalJumpError`), e soprattutto solo un'eccezione che ESCE da
    # `Net::HTTP#request` fa chiudere il socket. Uscendo in modo ordinato, `Net::HTTP` finirebbe di
    # scaricare da sé il corpo rimasto per completare la risposta — cioè proprio i megabyte che qui
    # si sta rifiutando di leggere (CYRA-807).
    BudgetReached = Class.new(StandardError)

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

    def initialize(url:, timeout: READ_TIMEOUT)
      @url = url.to_s
      @timeout = timeout
    end

    def call
      uri = parse(@url)
      return failure("invalid_url") if uri.nil?

      follow(uri, [])
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      failure("timeout")
    rescue StandardError => e
      failure(e.class.name.demodulize.underscore)
    end

    private

    def follow(uri, chain)
      return failure("too_many_redirects", chain) if chain.size > MAX_REDIRECTS

      # Ogni salto è una URL nuova, quindi una validazione nuova: la catena è dato del sito remoto.
      address = NetworkGuard.resolved_public_address(uri.host)
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
      rescue BudgetReached
        nil # letto quanto basta: il resto della risposta resta dov'è
      end

      [ response, body, truncated ]
    end

    def connection(uri, address)
      http = Net::HTTP.new(uri.host, uri.port)
      http.ipaddr = address # IP validato pinnato; Host header, SNI e verifica del certificato restano sull'host
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = @timeout
      http
    end

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
