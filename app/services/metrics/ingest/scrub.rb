# frozen_string_literal: true

module Metrics
  module Ingest
    # Metrics retain their diagnostic payload, scrubbed with the same rules as stored samples.
    class Scrub < ApplicationService
      include Scrubbing
      include ::Ingest::PayloadCleaning

      def initialize(payload:)
        @payload = payload
      end

      def call
        scrub_value(deep_clean(@payload.is_a?(Hash) ? @payload : {}))
      end
    end
  end
end
