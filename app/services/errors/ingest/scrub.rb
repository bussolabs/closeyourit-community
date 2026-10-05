# frozen_string_literal: true

require "uri"

module Errors
  module Ingest
    # Apply the error channel privacy policy before any durable staging or derived fields.
    class Scrub < ApplicationService
      include ::Ingest::PiiScrubbing

      NATIVE_TOKEN = /\bcyi_[A-Za-z0-9]{40}\b/
      BEARER = /\bBearer\s+[^\s,;]+/i
      URL = %r{https?://[^\s<>"']+}i
      TRACE_KEYS = %w[span_id parent_span_id].freeze

      def initialize(payload:)
        @payload = payload
      end

      def call
        clean(@payload)
      end

      private

      def clean(value, path = [])
        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            protocol_id = path == %w[contexts trace] && TRACE_KEYS.include?(key) && item.is_a?(String) && item.match?(/\A[0-9a-f]{16}\z/i)
            result[key] = sensitive_key?(key) && !protocol_id ? REDACTED : clean(item, path + [ key ])
          end
        when Array then value.map { |item| clean(item, path) }
        when String
          # Parse userinfo before email redaction can destroy URL boundaries.
          text = value.gsub(URL) { |url| safe_url(url) }
          scrub_message(text).gsub(NATIVE_TOKEN, REDACTED).gsub(BEARER, REDACTED)
        else value
        end
      end

      def safe_url(value)
        uri = URI.parse(value)
        uri.user = nil
        uri.password = nil
        uri.query = nil
        uri.fragment = nil
        uri.to_s
      rescue URI::InvalidURIError
        REDACTED
      end
    end
  end
end
