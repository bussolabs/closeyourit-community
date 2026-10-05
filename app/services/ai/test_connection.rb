# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Ai
  # "Test connection" in Valhalla (CYRA-916): one real, tiny call per capability with the values on
  # the form, before they are saved. Short timeouts: the admin is waiting on the page.
  # Each check is :ok, :failed (detail says why) or :off (not configured, so that feature stays off).
  # The embedding check also reports the size the model really returns, so the form can use it.
  class TestConnection < ApplicationService
    Check = Data.define(:key, :status, :detail)

    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 20

    def initialize(config:)
      @config = config
    end

    def call
      Result.ok([ chat, embeddings, transcription, rerank ])
    end

    private

    def chat
      return off(:chat) unless @config.chat_configured?

      check(:chat) do
        body = { model: @config.chat_model, max_tokens: 8, messages: [ { role: "user", content: "ping" } ] }
        body[:chat_template_kwargs] = { enable_thinking: false } unless @config.provider == "custom"
        payload = post(@config.chat_base_url, "/chat/completions", body, @config.api_key)
        payload.dig("choices", 0).present? ? nil : "no answer"
      end
    end

    def embeddings
      return off(:embeddings) unless @config.embeddings_configured?

      check(:embeddings) do
        payload = post(@config.embed_base_url, "/embeddings",
                       { model: @config.embedding_model, input: [ "healthcheck" ] }, @config.api_key)
        size = Array(payload.dig("data", 0, "embedding")).length
        next "no vector" if size.zero?
        next "size #{size}, expected #{@config.embedding_dimensions}" if size != @config.embedding_dimensions

        nil
      end
    end

    # Half a second of 16 kHz mono silence: the provider answers 200 with an empty text when the model
    # exists, so a wrong model shows here instead of at the first dictation (CYRA-914 D10).
    def transcription
      return off(:transcription) unless @config.transcription_configured?

      check(:transcription) do
        post_audio(@config.chat_base_url, @config.transcription_model, @config.api_key)
        nil
      end
    end

    SILENCE_SAMPLES = 8_000

    def silent_wav
      data = "\x00".b * (SILENCE_SAMPLES * 2)
      header = [ "RIFF", 36 + data.bytesize, "WAVE", "fmt ", 16, 1, 1, 16_000, 32_000, 2, 16, "data", data.bytesize ]
               .pack("a4Va4a4VvvVVvva4V")
      header + data
    end

    def post_audio(base_url, model, api_key)
      uri = URI.parse("#{base_url.to_s.chomp('/')}/audio/transcriptions")
      boundary = "cyi-#{SecureRandom.hex(8)}"
      body = "--#{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n#{model}\r\n" \
             "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"healthcheck.wav\"\r\n" \
             "Content-Type: audio/wav\r\n\r\n".b + silent_wav + "\r\n--#{boundary}--\r\n".b
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{api_key}"
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      request.body = body
      response = http_for(uri).request(request)
      raise "HTTP #{response.code}" unless response.code.to_i.between?(200, 299)
    end

    def rerank
      return off(:rerank) unless @config.rerank_configured?

      check(:rerank) do
        payload = post(@config.rerank_base_url, "/rerank",
                       { model: @config.rerank_model, query: "disk full", documents: [ "pasta recipe", "no space left" ] },
                       @config.rerank_api_key)
        payload["results"].is_a?(Array) ? nil : "no results"
      end
    end

    def check(key)
      problem = yield
      Check.new(key:, status: problem ? :failed : :ok, detail: problem)
    rescue StandardError => e
      Check.new(key:, status: :failed, detail: e.message.truncate(120))
    end

    def off(key) = Check.new(key:, status: :off, detail: nil)

    def post(base_url, path, body, api_key)
      uri = URI.parse("#{base_url.to_s.chomp('/')}#{path}")
      http = http_for(uri)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{api_key}"
      request["Content-Type"] = "application/json"
      request.body = body.to_json
      response = http.request(request)
      raise "HTTP #{response.code}" unless response.code.to_i.between?(200, 299)

      JSON.parse(response.body)
    end

    def http_for(uri)
      # An address the organization typed is checked like at call time (Ai::ProviderHttp, CYRA-914).
      untrusted = Ai::Configuration::URL_FIELDS.any? do |field|
        @config.sources[field] == :organization && uri.to_s.start_with?(@config.public_send(field).to_s.chomp("/"))
      end
      Ai::ProviderHttp.build(uri, untrusted:, open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS)
    end
  end
end
