# frozen_string_literal: true

module Errors
  # Temporary scrubbed payload and server-derived user hash, deleted after processing.
  # Queue arguments carry only this row's identifier. Legacy rows may have no user hash.
  class IngestPayload < ApplicationRecord
    self.table_name = "errors_ingest_payloads"

    belongs_to :project, class_name: "Projects::Project"
  end
end
