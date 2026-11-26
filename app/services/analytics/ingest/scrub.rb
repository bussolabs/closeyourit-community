# frozen_string_literal: true

module Analytics
  module Ingest
    # Discard unused visitor data before serialization; identity is supplied separately by the server.
    class Scrub < ApplicationService
      include ::Ingest::QueueScrubbing
      include ::Ingest::PayloadCleaning

      FIELDS = %w[event_id name hostname path referrer utm_source utm_medium utm_campaign
                  utm_term utm_content screen_width environment occurred_at properties].freeze

      def initialize(payload:)
        @payload = payload
      end

      def call
        return {} unless @payload.is_a?(Hash)

        cleaned = deep_clean(@payload.slice(*FIELDS))
        cleaned["properties"] = Properties.call(raw: cleaned["properties"])
        cleaned["path"] = strip_query(cleaned["path"].to_s) if cleaned.key?("path")
        cleaned["referrer"] = referrer(cleaned["referrer"]) if cleaned.key?("referrer")
        scrub_value(cleaned)
      end

      private

      def referrer(value)
        host = URI.parse(value.to_s).host
        "https://#{host}" if host.present?
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
