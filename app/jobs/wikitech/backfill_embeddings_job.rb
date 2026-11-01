# frozen_string_literal: true

module Wikitech
  # Re-embeds the cards whose checksum is stale (never embedded, text changed, new model). Nightly in
  # recurring.yml like the other domains, and started at once after an embedding model change.
  class BackfillEmbeddingsJob < ApplicationJob
    queue_as :batch

    def perform
      Wikitech::Entry.find_each do |entry|
        next if entry.embedding.present? && entry.embedding_checksum == Wikitech::EmbeddingText.checksum(entry: entry)

        Wikitech::EmbedEntryJob.perform_later(entry_id: entry.id)
      end
    end
  end
end
