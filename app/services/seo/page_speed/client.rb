# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Seo
  module PageSpeed
    # Client di PageSpeed Insights (CYRA-539). È l'unico punto che apre un socket verso Google.
    #
    # LA CHIAVE NON È OPZIONALE. La guida ufficiale dice che l'API «can be used with or without an
    # API key»: in pratica è falso — il consumer anonimo condiviso ha quota giornaliera ZERO, e
    # risponde 429 con `"quota_limit_value": "0"`. Verificato con una chiamata vera. Senza chiave
    # quindi non si chiama affatto: un ripiego che a volte funziona è un guasto intermittente
    # travestito da funzionalità.
    #
    # LA CHIAVE È UN ARGOMENTO OBBLIGATORIO (CYRA-546): la porta l'organizzazione a cui appartiene il
    # sito, non l'installazione. Il default da ENV è stato tolto di proposito e non va rimesso — un
    # default silenzioso rimetterebbe il consumo di tutte le organizzazioni sulla chiave di chi
    # gestisce l'installazione, che è ciò che questa lavorazione toglie di mezzo, e lo farebbe senza
    # che nessuno se ne accorga. Dimenticarla ora è un `ArgumentError` al primo giro di prove.
    #
    # NON si pinna l'IP come fa `Seo::Fetch`, e la differenza va detta: lì si parla alla URL del
    # CLIENTE, che potrebbe puntare a un indirizzo interno; qui si parla a Google, un host fisso
    # scritto in una costante. La URL del cliente viaggia però come parametro di query, quindi va
    # codificata e la sua validità la garantisce già la validazione di `Seo::Site#base_url`.
    class Client
      class Error < StandardError
        attr_reader :code, :reason

        def initialize(message, code:, reason:)
          super(message)
          @code = code
          @reason = reason
        end
      end

      # → il client con la chiave dell'organizzazione, oppure NIL se quell'organizzazione non ha
      # collegato il servizio. Nil e non un'eccezione: «non collegato» non è un guasto, è una
      # configurazione che manca, e il chiamante deve poterlo dire a chi guarda invece di finire in
      # un rescue insieme ai timeout del fornitore.
      def self.for(organization:, **options)
        api_key = Integrations::Resolve.api_key(organization: organization, provider: :pagespeed)
        return if api_key.nil?

        new(api_key: api_key, **options)
      end

      # La chiave deve esistere E non essere vuota. Una chiave salvata vuota manderebbe un `key=`
      # vuoto e Google risponderebbe come al consumer anonimo — cioè quota ZERO, un guasto che si
      # legge come «il sito non è misurabile». KeyError esplicito PRIMA della chiamata: è la difesa
      # di chi costruisce il client a mano, perché chi passa da `.for` non ci arriva mai (una
      # credenziale vuota lì è già «non collegato», `Integrations::Resolve` usa `.presence`).
      def initialize(api_key:, base_url: Constants::BASE_URL)
        raise KeyError, "chiave PageSpeed vuota" if api_key.to_s.strip.blank?

        @api_key = api_key.to_s.strip
        @base_url = base_url
      end

      # → Hash della risposta (già filtrata dalla maschera `fields`).
      def run(url:, strategy:)
        request(query_for(url:, strategy:))
      end

      private

      def query_for(url:, strategy:)
        query_params = [ [ "url", url ], [ "strategy", strategy.to_s ], [ "locale", Constants::LOCALE ],
                      [ "key", @api_key ] ]
        query_params += Constants::CATEGORIES.map { |category| [ "category", category ] }
        query_params << [ "fields", Constants::FIELDS ]
        URI.encode_www_form(query_params)
      end

      def request(query)
        uri = URI.join(@base_url, Constants::PATH)
        uri.query = query

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = Constants::OPEN_TIMEOUT_SECONDS
        http.read_timeout = Constants::READ_TIMEOUT_SECONDS

        req = Net::HTTP::Get.new(uri)
        req["Accept"] = "application/json"

        handle(http.request(req))
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
        raise Error.new("PageSpeed non ha risposto in tempo", code: "R502-PAGESPEED-002", reason: "timeout")
      rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError
        raise Error.new("PageSpeed irraggiungibile", code: "R502-PAGESPEED-002", reason: "upstream_error")
      end

      def handle(response)
        code = response.code.to_i
        return parse(response.body) if code.between?(200, 299)

        raise error_for(code, response.body)
      end

      # La tassonomia degli errori è corta e in stringhe, come quella del crawler: chi legge la
      # scheda deve capire perché la misura non c'è, non ricevere un codice HTTP.
      def error_for(code, body)
        case code
        when 429 then Error.new("Quota PageSpeed esaurita", code: "R429-PAGESPEED-001", reason: "quota_exceeded")
        when 401, 403 then Error.new("Chiave PageSpeed rifiutata", code: "R502-PAGESPEED-003", reason: "unauthorized")
        when 400 then Error.new(lighthouse_message(body), code: "R502-PAGESPEED-004", reason: lighthouse_reason(body))
        else Error.new("PageSpeed ha risposto #{code}", code: "R502-PAGESPEED-002", reason: "upstream_error")
        end
      end

      # Un 400 può essere «la URL non va bene» oppure «Lighthouse non è riuscito a caricarla»: sono
      # due cose diverse per chi legge, e il messaggio di Google lo dice.
      def lighthouse_reason(body)
        json = JSON.parse(body.to_s)
        json.dig("error", "message").to_s.match?(/lighthouse|chrome/i) ? "lighthouse_error" : "invalid_url"
      rescue JSON::ParserError
        "invalid_url"
      end

      def lighthouse_message(body)
        JSON.parse(body.to_s).dig("error", "message").presence || "PageSpeed ha rifiutato la richiesta"
      rescue JSON::ParserError
        "PageSpeed ha rifiutato la richiesta"
      end

      def parse(raw)
        json = JSON.parse(raw.to_s)
        raise Error.new("Risposta PageSpeed inattesa", code: "R502-PAGESPEED-005", reason: "unreadable") unless json.is_a?(Hash)

        json
      rescue JSON::ParserError
        raise Error.new("Risposta PageSpeed illeggibile", code: "R502-PAGESPEED-005", reason: "unreadable")
      end
    end
  end
end
