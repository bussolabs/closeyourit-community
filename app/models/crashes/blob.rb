# frozen_string_literal: true

module Crashes
  # No ActiveStorage::Blob exists: signed engine URLs cannot bypass project authorization.
  class Blob < ApplicationRecord
    has_one :attachment, class_name: "Crashes::Attachment", foreign_key: :blob_id, inverse_of: :blob
    validates :byte_size, numericality: { only_integer: true, in: 0..MAX_FILE }

    def service
      ActiveStorage::Blob.services.fetch(service_name)
    end

    def purge!
      # Delete storage first. A failed object deletion leaves this row available for retry.
      service.delete(key)
      destroy!
    end
  end
end
