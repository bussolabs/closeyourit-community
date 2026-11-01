# frozen_string_literal: true

module Wikitech
  # Computes and stores the embedding of a card. Idempotent: same checksum, no call. A failing
  # embedding service only leaves the card out of the search by meaning until the nightly backfill.
  class EmbedEntryJob < ApplicationJob
    queue_as :embeddings

    def perform(entry_id:)
      entry = Wikitech::Entry.find_by(id: entry_id)
      return if entry.nil?

      Current.organization = entry.organization # runs with this organization's AI settings (CYRA-914)
      checksum = Wikitech::EmbeddingText.checksum(entry: entry)
      return if entry.embedding.present? && entry.embedding_checksum == checksum

      result = Embeddings::EmbedText.call(text: Wikitech::EmbeddingText.call(entry: entry),
                                          label: "Wikitech::Entry #{entry.id}")
      raise result.error if result.err?

      entry.update_columns(embedding: result.value, embedding_checksum: checksum, embedded_at: Time.current,
                           embedding_version: Ai::Configuration.current.embedding_version)
    end
  end
end
