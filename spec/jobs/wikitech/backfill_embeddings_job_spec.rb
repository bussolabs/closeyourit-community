# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wikitech::BackfillEmbeddingsJob do
  it "queues only the cards whose embedding is missing or stale" do
    stale = create(:wikitech_entry)
    fresh = create(:wikitech_entry)
    fresh.update_columns(embedding: Array.new(1024, 0.1), embedding_checksum: Wikitech::EmbeddingText.checksum(entry: fresh))

    expect { described_class.perform_now }
      .to have_enqueued_job(Wikitech::EmbedEntryJob).with(entry_id: stale.id).exactly(:once)
  end
end
