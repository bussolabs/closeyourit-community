# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Ai
  module Embedding
    # Client del servizio embedding/rerank: LiteLLM sul server AI di casa (CYRA-758), prima il
    # container closeyourit-embedding su sentinel. Endpoint OpenAI-compatible SINCRONI sotto
    # EMBED_BASE_URL: POST embeddings (Qwen3-Embedding-0.6B, dim 1024) e POST rerank
    # (Qwen3-Reranker-0.6B dietro l'alias di EMBED_RERANK_MODEL, risposta in formato Cohere:
    # `results[].relevance_score`). Auth
    # `Authorization: Bearer` con la virtual key LiteLLM. Isola il trasporto dal dominio: i service
    # usano Embeddings::* e non sanno nulla di HTTP.
    #
    # Chiave e base URL da ENV (mai hardcoded): AI_API_KEY / EMBED_BASE_URL. La base URL porta
    # il prefisso `/v1` (`https://ai.example.com/v1`): i path si APPENDONO, non si
    # risolvono con URI.join, che con un path assoluto scarterebbe il prefisso e chiamerebbe
    # `/embeddings` alla radice del proxy → 404 "Not Found".
    class Client
      # Errore di trasporto/servizio con codice R{STATUS}-AI-{SEQ}, mappato dal service in AppError.
      class Error < StandardError
        attr_reader :code, :status

        def initialize(message, code:, status: :bad_gateway)
          super(message)
          @code = code
          @status = status
        end
      end

      # Addresses, keys and models come from Ai::Configuration (CYRA-916). Missing ones raise
      # KeyError here, which the callers already report as «not configured».
      def initialize(api_key: Ai::Configuration.current.api_key, base_url: Ai::Configuration.current.embed_base_url)
        raise KeyError, "AI_API_KEY vuota" if api_key.blank?
        raise KeyError, "EMBED_BASE_URL vuota" if base_url.blank?

        @api_key = api_key
        @base_url = base_url
      end

      # Ritorna gli embedding come Array di Array<Float>, nell'ordine degli input (il servizio
      # risponde con `index` per elemento — riordiniamo per sicurezza). `input` String o Array.
      def embed(input:)
        model = Ai::Configuration.current.embedding_model
        raise KeyError, "embedding model not configured" if model.blank?

        payload = request("/embeddings", { model:, input: Array(input) })
        data = payload["data"]
        raise malformed_error unless data.is_a?(Array) && data.any?

        vectors = data.sort_by { |item| item["index"].to_i }.map { |item| item["embedding"] }
        raise malformed_error unless vectors.all? { |vector| vector.is_a?(Array) && vector.any? }

        vectors
      end

      # Riordina `documents` per pertinenza rispetto a `query` (cross-encoder). Ritorna
      # [{ index:, score: }] ordinato per score decrescente; `index` riferisce l'array in input.
      #
      # `read_timeout` è il tetto di attesa del chiamante: la ricerca interattiva ne passa uno
      # corto e degrada se scade, il RAG in coda lascia il default lungo (CYRA-553).
      #
      # Senza alias (`EMBED_RERANK_MODEL` assente) solleva PRIMA di aprire la connessione: nessun
      # giro di rete sprecato per ogni ricerca, e un codice 503 distinto dal servizio giù.
      def rerank(query:, documents:, read_timeout: nil)
        model, base_url, api_key = rerank_target
        if [ model, base_url, api_key ].any?(&:blank?)
          raise Error.new("Rerank non configurato", code: "R503-AI-002", status: :service_unavailable)
        end

        payload = request("/rerank", { model:, query:, documents: }, read_timeout:, base_url:, api_key:)
        results = payload["results"]
        raise malformed_error unless results.is_a?(Array) && results.any?

        results.map { |item| { index: item["index"].to_i, score: item["relevance_score"].to_f } }
               .sort_by { |item| -item[:score] }
      end

      private

      # From the environment, rerank shares this client's address and key; a provider chosen in
      # Valhalla may point it somewhere else (Cohere, Jina, Voyage).
      def rerank_target
        config = Ai::Configuration.current
        return [ config.rerank_model, @base_url, @api_key ] if config.provider.nil?

        [ config.rerank_model, config.rerank_base_url, config.rerank_api_key ]
      end

      def request(path, body, read_timeout: nil, base_url: @base_url, api_key: @api_key)
        uri = URI.parse("#{base_url.to_s.chomp("/")}#{path}")
        http = Ai::ProviderHttp.build(uri, untrusted: Ai::Configuration.current.untrusted_url?(base_url),
                                           open_timeout: Ai::Constants::EMBED_OPEN_TIMEOUT_SECONDS,
                                           read_timeout: read_timeout || Ai::Constants::EMBED_READ_TIMEOUT_SECONDS)

        req = Net::HTTP::Post.new(uri)
        req["Authorization"] = "Bearer #{api_key}"
        req["Content-Type"] = "application/json"
        req.body = body.to_json

        response = http.request(req)
        case response.code.to_i
        when 200 then parse(response.body)
        when 401, 403 then raise Error.new("Embedding auth fallita (#{response.code})", code: "R502-AI-002")
        when 402 then raise Error.new(I18n.t("ai.limit_reached"), code: "R402-AI-001", status: :payment_required)
        else raise Error.new("Embedding errore upstream (#{response.code})", code: "R502-AI-001")
        end
      rescue Ai::ProviderHttp::BlockedAddress => e
        raise Error.new(e.message, code: "R422-AI-008", status: :unprocessable_entity)
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
        raise Error.new("Embedding timeout", code: "R504-AI-001", status: :gateway_timeout)
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE,
             Errno::ETIMEDOUT, SocketError, IOError, OpenSSL::SSL::SSLError
        # Da HTTPS pubblico (CYRA-758) arrivano anche reset, chiusure a metà e TLS rotto: tutti «servizio
        # non raggiungibile», mai un 500 — i chiamanti intercettano solo Client::Error e degradano.
        raise Error.new("Embedding servizio non raggiungibile", code: "R502-AI-001")
      end

      def parse(raw)
        JSON.parse(raw.to_s)
      rescue JSON::ParserError
        raise Error.new("Embedding risposta non valida", code: "R502-AI-003")
      end

      def malformed_error
        Error.new("Embedding risposta malformata", code: "R502-AI-005")
      end
    end
  end
end
