# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Vulnerabilities
  module Eol
    # Client di endoflife.date: per ogni prodotto, i cicli di rilascio con la data di fine supporto.
    #
    # La risposta è identica per tutti i progetti (è un calendario pubblico, non un dato nostro),
    # quindi si tiene in cache per un giorno: senza, dieci progetti su Ruby farebbero dieci volte la
    # stessa richiesta a ogni giro.
    #
    # Un prodotto sconosciuto (404) NON è un errore: endoflife.date non copre tutto — Flutter e Dart,
    # per dire, non ci sono. In quel caso non sappiamo nulla e non diciamo nulla.
    class Client
      class Error < StandardError
        attr_reader :code, :status

        def initialize(message, code:, status: :bad_gateway)
          super(message)
          @code = code
          @status = status
        end
      end

      API_BASE = "https://endoflife.date"
      OPEN_TIMEOUT_SECONDS = 5
      READ_TIMEOUT_SECONDS = 10
      CACHE_TTL = 24.hours

      def initialize(base_url: ENV.fetch("EOL_BASE_URL", API_BASE))
        @base_url = base_url
      end

      # → [{ "cycle", "eol", "latest", … }] oppure nil se il prodotto non è coperto.
      def cycles(product)
        Rails.cache.fetch(cache_key(product), expires_in: CACHE_TTL) do
          request("/api/#{URI.encode_www_form_component(product)}.json")
        end
      end

      private

      def cache_key(product) = "vulnerabilities:eol:#{product}"

      def request(path)
        uri = URI.join(@base_url, path)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT_SECONDS
        http.read_timeout = READ_TIMEOUT_SECONDS

        req = Net::HTTP::Get.new(uri)
        req["Accept"] = "application/json"

        handle(http.request(req))
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
        raise Error.new("endoflife.date timeout", code: "R502-EOL-001")
      rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError
        raise Error.new("endoflife.date irraggiungibile", code: "R502-EOL-001")
      end

      def handle(response)
        code = response.code.to_i
        return parse(response.body) if code.between?(200, 299)
        # Prodotto non coperto dal calendario: nessun dato, nessun allarme.
        return nil if code == 404

        raise Error.new("endoflife.date errore (#{code})", code: "R502-EOL-001")
      end

      def parse(raw)
        data = JSON.parse(raw.to_s)
        data.is_a?(Array) ? data : nil
      rescue JSON::ParserError
        raise Error.new("endoflife.date risposta non valida", code: "R502-EOL-002")
      end
    end
  end
end
