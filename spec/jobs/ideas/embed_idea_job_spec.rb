# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::EmbedIdeaJob, type: :job do
  let(:idea) { create(:idea) }

  it "calcola e persiste embedding + checksum + embedded_at + versione" do
    vector = basis_vector(0)
    allow(Embeddings::EmbedText).to receive(:call).and_return(Result.ok(vector))

    freeze_time do
      described_class.perform_now(idea_id: idea.id)
      idea.reload
      expect(idea.embedding.map(&:to_f)).to eq(vector)
      expect(idea.embedding_checksum).to eq(Ideas::EmbeddingText.checksum(idea: idea))
      expect(idea.embedded_at).to eq(Time.current)
      expect(idea.embedding_version).to eq(Ai::Constants::EMBEDDING_VERSION)
    end
  end

  it "non tocca updated_at: l'ordinamento della bacheca è l'ultimo movimento umano" do
    allow(Embeddings::EmbedText).to receive(:call).and_return(Result.ok(basis_vector(0)))
    before = idea.updated_at

    travel_to(1.hour.from_now) { described_class.perform_now(idea_id: idea.id) }

    expect(idea.reload.updated_at).to eq(before)
  end

  it "è idempotente: checksum invariato → nessuna nuova chiamata al servizio" do
    idea.update_columns(embedding: basis_vector(0),
                        embedding_checksum: Ideas::EmbeddingText.checksum(idea: idea))
    allow(Embeddings::EmbedText).to receive(:call)

    described_class.perform_now(idea_id: idea.id)
    expect(Embeddings::EmbedText).not_to have_received(:call)
  end

  it "idea sparita → no-op silenzioso" do
    expect { described_class.perform_now(idea_id: SecureRandom.uuid) }.not_to raise_error
  end

  it "errore del servizio → retry accodato (retry_on), embedding resta intatto" do
    allow(Embeddings::EmbedText).to receive(:call)
      .and_return(Result.err(AppError.new("giù", code: "R502-AI-001", status: :bad_gateway)))

    expect { described_class.perform_now(idea_id: idea.id) }
      .to have_enqueued_job(described_class).with(idea_id: idea.id)
    expect(idea.reload.embedding).to be_nil
  end
end
