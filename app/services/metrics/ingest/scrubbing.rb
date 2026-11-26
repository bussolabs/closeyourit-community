# frozen_string_literal: true

module Metrics
  module Ingest
    # Shared by the queue boundary and normalization; technical IDs must not match partial words.
    module Scrubbing
      include ::Ingest::QueueScrubbing

      UUID_RE = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i
      SENSITIVE_SEGMENT = /\A(?:password|passwd|pwd|secret|token|bearer|authorization|cookie|csrf|session|pin|cvv|pan|ssn|iban|email|mail|phone|telephone|mobile|dob|birth|passport|credit|card)\z/
      SENSITIVE_COMPOUND = /apikey/
      URL_KEY = /\A(url|uri|href|http_url|http_path|location|referer|referrer)\z/i
      SQL_KEY = /\Asql\z/i

      def templatize(text)
        text.to_s
            .gsub(/\$([a-z0-9_]*)\$.*?\$\1\$/mi, "<str>")
            .gsub(/'(?:[^']|'')*'/, "<str>")
            .gsub(UUID_RE, "<uuid>")
            .gsub(/\b0x[0-9a-f]+\b/i, "<hex>")
            .gsub(/\d+/, "<n>")
      end

      def scrub_entry(key, value)
        return scrub_sql(value) if SQL_KEY.match?(privacy_key(key)) && value.is_a?(String)

        super
      end

      # Comments are scrubbed, not dropped: query log tags (controller, action) stay part of the
      # signature, so samples keep grouping with the ones stored before the queue scrub.
      def scrub_sql(value)
        templated = templatize(value.gsub(::Ingest::PiiScrubbing::EMAIL_IN_TEXT, ::Ingest::PiiScrubbing::REDACTED))
        templated.gsub(%r{/\*.*?\*/}m) { |comment| scrub_message(comment) }
                 .gsub(/--[^\r\n]*/) { |comment| scrub_message(comment) }
      end

      def sensitive_key?(key)
        normalized = key.to_s.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
        ::Ingest::QueueScrubbing::ADDRESS_KEY.match?(privacy_key(key)) || sensitive_header?(key) ||
          normalized.split(/[^a-z\d]+/).any? { |segment| SENSITIVE_SEGMENT.match?(segment) } ||
          SENSITIVE_COMPOUND.match?(normalized.gsub(/[^a-z\d]/, ""))
      end

      def url_key?(key) = URL_KEY.match?(privacy_key(key))
    end
  end
end
