# frozen_string_literal: true

module Artifacts
  # Lifecycle rows outlive tenant deletion until private object deletion succeeds.
  class Blob < ApplicationRecord
    def service = ActiveStorage::Blob.services.fetch(service_name)

    def purge!
      Timeout.timeout(3, Unavailable, "Artifact deletion deadline exceeded") { service.delete(key) }
      destroy!
    end
  end
end
