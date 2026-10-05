# frozen_string_literal: true

module Helpdesk
  # Re-embeds the requests whose checksum is stale (never embedded, text changed, or a new embedding
  # model), like its ticket, error, knowledge and idea twins. Runs daily and after a model change
  # (Embeddings::ResizeColumnsJob, CYRA-914 P8).
  class BackfillEmbeddingsJob < ApplicationJob
    queue_as :batch

    def perform
      Helpdesk::Request.includes(:project).find_each do |request|
        next if request.embedding.present? &&
                request.embedding_checksum == Helpdesk::EmbeddingText.checksum(request: request)

        Helpdesk::EmbedRequestJob.perform_later(request_id: request.id)
      end
    end
  end
end
