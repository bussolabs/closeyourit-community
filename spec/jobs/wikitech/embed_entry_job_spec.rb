# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wikitech::EmbedEntryJob do
  let(:entry) { create(:wikitech_entry) }
  let(:vector) { Array.new(1024, 0.1) }

  it "stores the embedding with checksum and version, then skips an unchanged card" do
    allow(Embeddings::EmbedText).to receive(:call).and_return(Result.ok(vector))

    described_class.perform_now(entry_id: entry.id)
    described_class.perform_now(entry_id: entry.id)

    expect(Embeddings::EmbedText).to have_received(:call).once
    expect(entry.reload.embedding_checksum).to eq(Wikitech::EmbeddingText.checksum(entry: entry))
    expect(entry.embedding_version).to eq(Ai::Configuration.current.embedding_version)
  end

  it "retries when the embedding service is down" do
    allow(Embeddings::EmbedText).to receive(:call).and_return(Result.err(AppError.new("x", code: "R502-AI-001")))

    expect { described_class.perform_now(entry_id: entry.id) }.to have_enqueued_job(described_class)
  end

  it "ignores a card that no longer exists" do
    expect { described_class.perform_now(entry_id: SecureRandom.uuid) }.not_to raise_error
  end
end
