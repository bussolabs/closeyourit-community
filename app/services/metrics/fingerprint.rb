# frozen_string_literal: true

module Metrics
  # Chiave di deduplica di un campione: occorrenze con la stessa signature nello stesso progetto
  # formano UN Metrics::Group. La signature include già il kind (vedi Metrics::Ingest::Normalize).
  class Fingerprint < ApplicationService
    def initialize(signature:)
      @signature = signature.to_s
    end

    def call
      Digest::SHA256.hexdigest(@signature)
    end
  end
end
