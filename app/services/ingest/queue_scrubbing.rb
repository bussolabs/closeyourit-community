# frozen_string_literal: true

module Ingest
  # Queue payloads also scrub free text in nested arrays and URL paths, not just sensitive keys.
  module QueueScrubbing
    include PiiScrubbing

    ADDRESS_KEY = /\A(?:ip|ip_address|remote_ip|client_ip|user_agent|user|username|user_name|address|full_name|first_name|last_name)\z/i
    URL_IN_TEXT = %r{https?://[^\s"'<>)]+}
    ENCODED_EMAIL = /(?:[\w.+\-]|%[0-9a-f]{2})+%40(?:[\w.\-]|%[0-9a-f]{2})+/i

    def sensitive_key?(key)
      ADDRESS_KEY.match?(privacy_key(key)) || sensitive_header?(key) || super
    end

    def sensitive_header?(key)
      PiiScrubbing::SENSITIVE_HEADER.match?(privacy_key(key))
    end

    def scrub_value(value)
      value.is_a?(String) ? scrub_message(value) : super
    end

    def scrub_hash(hash)
      hash.to_h { |key, value| [ scrub_message(key), scrub_entry(key, value) ] }
    end

    def strip_query(value)
      scrub_message(clean_url(value))
    end

    def scrub_message(value)
      return value unless value.is_a?(String)

      super(value.gsub(URL_IN_TEXT) { |url| clean_url(url) }.gsub(ENCODED_EMAIL, PiiScrubbing::REDACTED))
    end

    private

    def clean_url(value)
      value.split(/[?#]/, 2).first.to_s.sub(%r{(https?://)[^/@]+@}, '\1')
    end
  end
end
