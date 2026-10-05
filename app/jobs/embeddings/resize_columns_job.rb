# frozen_string_literal: true

module Embeddings
  # Runs after the admin confirmed a new embedding model in Valhalla (CYRA-916): resizes the
  # columns when the size changed, then starts the backfills at once instead of waiting for 4am.
  # A model change with the same size needs no resize: the new embedding version alone makes the
  # backfills embed everything again.
  class ResizeColumnsJob < ApplicationJob
    queue_as :batch

    BACKFILLS = [ Ticketing::BackfillEmbeddingsJob, Errors::BackfillEmbeddingsJob,
                  Knowledge::BackfillEmbeddingsJob, Ideas::BackfillEmbeddingsJob,
                  Helpdesk::BackfillEmbeddingsJob ].freeze

    def perform(dimensions:)
      result = ResizeColumns.call(dimensions:)
      return Rails.logger.error("[embeddings] resize refused: #{result.error.message}") if result.err?

      BACKFILLS.each(&:perform_later)
    end
  end
end
