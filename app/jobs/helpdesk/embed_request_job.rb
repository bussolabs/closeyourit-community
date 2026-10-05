# frozen_string_literal: true

module Helpdesk
  # Computes and stores the embedding of a request (CYRA-943). Idempotent on the checksum. On a
  # service error it raises: ApplicationJob retries, then the request simply stays ungrouped.
  class EmbedRequestJob < ApplicationJob
    queue_as :embeddings

    def perform(request_id:)
      request = Helpdesk::Request.find_by(id: request_id)
      return if request.nil?
      Current.organization = request.project.organization # runs with this organization's AI settings (CYRA-914)

      checksum = Helpdesk::EmbeddingText.checksum(request: request)
      return if request.embedding.present? && request.embedding_checksum == checksum

      result = Embeddings::EmbedText.call(text: Helpdesk::EmbeddingText.call(request: request),
                                          label: "Helpdesk::Request #{request.id}")
      raise result.error if result.err?

      # update_columns: infrastructure columns, no validations and no updated_at.
      request.update_columns(embedding: result.value, embedding_checksum: checksum,
                             embedded_at: Time.current,
                             embedding_version: Ai::Configuration.current.embedding_version)
    end
  end
end
