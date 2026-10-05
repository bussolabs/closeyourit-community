# frozen_string_literal: true

module Errors
  module Ingest
    # Scrub before durable staging. Queue arguments contain only the row identifier;
    # the separate user hash is trusted metadata calculated before removing PII.
    class Enqueue < ApplicationService
      def initialize(project:, payload:)
        @project = project
        @payload = payload
      end

      def call
        normalized = Normalize.call(payload: @payload)
        staged = Errors::IngestPayload.create!(project: @project, payload: normalized.payload,
                                               user_hash: normalized.user_hash)
        Errors::IngestJob.perform_later(payload_id: staged.id)
        staged
      end
    end
  end
end
