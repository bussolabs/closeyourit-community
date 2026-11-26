# frozen_string_literal: true

module Logs
  module Ingest
    # Keep the wire format: timestamps and derived fields are normalized only in the worker.
    class Scrub < ApplicationService
      include ::Ingest::QueueScrubbing
      include ::Ingest::PayloadCleaning

      FIELDS = %w[event_id timestamp level message attributes logger trace_id environment release sdk].freeze

      def initialize(payload:)
        @payload = payload
      end

      def call
        return {} unless @payload.is_a?(Hash)

        cleaned = scrub_value(deep_clean(@payload.slice(*FIELDS)))
        cleaned["sdk"] = cleaned["sdk"].slice("name", "version") if cleaned["sdk"].is_a?(Hash)
        cleaned
      end
    end
  end
end
