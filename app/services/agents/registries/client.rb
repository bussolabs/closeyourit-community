# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Agents
  module Registries
    # CYRA-625 — lo scaffale pubblico, guardato da fuori come farebbe chi installa il pacchetto.
    #
    # Prima il sistema chiedeva al lavoro di pubblicazione com'era andata, e «finito senza errori»
    # non è «il pacchetto è sullo scaffale»: sul progetto Python l'etichetta 0.2.0 stava nel
    # repository da due settimane e mezzo mentre il magazzino portava ancora la 0.1.0, e nessuno se
    # n'era accorto.
    #
    # L'host sta in una COSTANTE, mai nel descrittore: un host che arriva da un dato è un host che
    # qualcuno può cambiare, e la prova andrebbe a guardare uno scaffale diverso da quello che dice
    # di guardare. Net::HTTP raw come gli altri provider del repo.
    class Client
      class Error < StandardError
        attr_reader :code

        def initialize(message, code:)
          super(message)
          @code = code
        end
      end

      OPEN_TIMEOUT_SECONDS = 5
      READ_TIMEOUT_SECONDS = 15

      # Alfabeto di ogni famiglia. Si valida PRIMA che parta qualunque chiamata: un nome che contiene
      # una barra risalente, uno spazio o — peggio — un indirizzo intero cambierebbe l'indirizzo
      # interrogato, perché la composizione di indirizzi butta via la base quando il secondo pezzo è
      # assoluto. Qui non si ripulisce niente: si rifiuta.
      ALPHABETS = {
        "npm" => /\A(@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*\z/,
        "pub" => /\A[a-z_][a-z0-9_]*\z/,
        "rubygems" => /\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/,
        "pypi" => /\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/
      }.freeze

      # La versione finisce nello stesso percorso, quindi ha la stessa regola.
      VERSION_FORMAT = /\A[a-zA-Z0-9][a-zA-Z0-9.+_-]*\z/

      HOST = {
        "npm" => "https://registry.npmjs.org",
        "pub" => "https://pub.dev",
        "rubygems" => "https://rubygems.org",
        "pypi" => "https://pypi.org"
      }.freeze

      def self.for(family)
        case family.to_s
        when "npm" then Agents::Registries::Npm.new
        when "pub" then Agents::Registries::Pub.new
        when "rubygems" then Agents::Registries::Rubygems.new
        when "pypi" then Agents::Registries::Pypi.new
        end
      end

      # { presente:, ritirata:, puntatore:, sha:, indirizzo: } — o solleva. `indirizzo` è quello
      # DAVVERO interrogato: il motivo che finisce sulla scheda lo prende da qui, non ricomposto a
      # parte, così non può nascondere una richiesta diversa da quella fatta.
      def lookup(_package, _version) = raise NotImplementedError

      private

      def family = self.class.name.demodulize.underscore

      def validate!(package, version)
        alphabet = ALPHABETS.fetch(family)
        raise Error.new("nome pacchetto fuori alfabeto", code: "R422-REGISTRY-001") unless
          package.is_a?(String) && alphabet.match?(package)
        raise Error.new("versione fuori alfabeto", code: "R422-REGISTRY-001") unless
          version.is_a?(String) && VERSION_FORMAT.match?(version)
      end

      # Il percorso si compone a pezzi codificati sulla base costante: mai `URI.join`, che con un
      # secondo pezzo assoluto butta via la base e chiama l'host scritto dentro il nome.
      def url_for(*parts)
        "#{HOST.fetch(family)}/#{parts.map { |part| URI.encode_www_form_component(part) }.join('/')}"
      end

      def get(url, allow_not_found: false)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT_SECONDS
        http.read_timeout = READ_TIMEOUT_SECONDS

        req = Net::HTTP::Get.new(uri)
        req["Accept"] = "application/json"
        handle(http.request(req), allow_not_found:)
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
        raise Error.new("registro in timeout", code: "R502-REGISTRY-001")
      rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError
        raise Error.new("registro irraggiungibile", code: "R502-REGISTRY-001")
      end

      def handle(response, allow_not_found:)
        code = response.code.to_i
        return parse(response.body) if code.between?(200, 299)
        # «Quella versione non esiste» e «quel pacchetto non esiste» sono la risposta normale finché
        # la pubblicazione non è arrivata — al primo rilascio di un pacchetto nuovo lo sono sempre.
        # Non è una negazione: è un «non ancora», e chi chiama riprova.
        return nil if allow_not_found && code == 404
        raise Error.new("registro ha risposto troppe richieste", code: "R502-REGISTRY-003") if code == 429

        raise Error.new("registro ha risposto #{code}", code: "R502-REGISTRY-001")
      end

      # Un corpo illeggibile è una linea storta, non una negazione: si riprova, non si chiama nessuno.
      def parse(raw)
        return {} if raw.to_s.strip.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        raise Error.new("registro ha risposto qualcosa che non si legge", code: "R502-REGISTRY-002")
      end
    end
  end
end
