# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Vulnerabilities
  module Osv
    # Client di OSV.dev, il database pubblico di vulnerabilità open source (Google). Net::HTTP raw
    # come tutti gli altri provider del repo: nessuna gem HTTP.
    #
    # Due endpoint bastano:
    # - `POST /v1/querybatch` → per ogni coppia pacchetto+versione, la lista degli id che la colpiscono.
    #   È deliberatamente magro (solo id e data di modifica): serve a scoprire COSA guardare.
    # - `GET /v1/vulns/:id` → il record completo (gravità, alias CVE, versioni che risolvono).
    #
    # Il servizio è gratuito e senza rate limit dichiarato, ma la latenza del batch non è banale
    # (P90 ~4s per richiesta): il read timeout è largo di conseguenza.
    class Client
      class Error < StandardError
        attr_reader :code, :status

        def initialize(message, code:, status: :bad_gateway)
          super(message)
          @code = code
          @status = status
        end
      end

      API_BASE = "https://api.osv.dev"
      OPEN_TIMEOUT_SECONDS = 5
      READ_TIMEOUT_SECONDS = 20 # querybatch: P90 ≤ 4s, P95 ≤ 6s dichiarati — il margine è voluto

      def initialize(base_url: ENV.fetch("OSV_BASE_URL", API_BASE))
        @base_url = base_url
      end

      # `queries` = [{ ecosystem:, name:, version: }, …] → array PARALLELO di array di id.
      # La posizione è il contratto: il risultato i-esimo appartiene alla query i-esima, e una query
      # senza vulnerabilità dà un array vuoto (non viene omessa).
      def query_batch(queries)
        return [] if queries.blank?

        payload = {
          queries: queries.map do |query|
            {
              package: { name: query[:name], ecosystem: query[:ecosystem] },
              version: query[:version]
            }
          end
        }

        data = request(Net::HTTP::Post, "/v1/querybatch", body: payload)
        results = data["results"] || []
        # Difesa sul contratto posizionale: se il servizio rispondesse con meno risultati delle query,
        # allineare per indice attribuirebbe vulnerabilità al pacchetto sbagliato.
        raise Error.new("OSV risposta disallineata", code: "R502-OSV-002") if results.size != queries.size

        results.map { |result| (result["vulns"] || []).filter_map { |vuln| vuln["id"] } }
      end

      # Record completo di una vulnerabilità. Un id sconosciuto dà nil (un advisory può essere
      # ritirato fra il batch e la lettura), non un errore.
      def vulnerability(osv_id)
        request(Net::HTTP::Get, "/v1/vulns/#{URI.encode_www_form_component(osv_id)}",
                allow_not_found: true)
      end

      private

      def request(method_class, path, body: nil, allow_not_found: false)
        uri = URI.join(@base_url, path)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT_SECONDS
        http.read_timeout = READ_TIMEOUT_SECONDS

        req = method_class.new(uri)
        req["Accept"] = "application/json"
        if body
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end

        handle(http.request(req), allow_not_found:)
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
        raise Error.new("OSV timeout", code: "R502-OSV-001")
      rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError
        raise Error.new("OSV irraggiungibile", code: "R502-OSV-001")
      end

      def handle(response, allow_not_found:)
        code = response.code.to_i
        return parse(response.body) if code.between?(200, 299)
        return nil if allow_not_found && code == 404

        raise Error.new("OSV API errore (#{code})", code: "R502-OSV-001")
      end

      def parse(raw)
        return {} if raw.to_s.strip.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        raise Error.new("OSV risposta non valida", code: "R502-OSV-002")
      end
    end
  end
end
