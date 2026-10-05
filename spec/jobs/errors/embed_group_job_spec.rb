# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::EmbedGroupJob do
  let(:group) { create(:error_group) }

  it "embedda title+culprit e persiste vettore+checksum+timestamp" do
    vector = basis_vector(2)
    allow(Embeddings::EmbedText).to receive(:call)
      .with(text: Errors::EmbeddingText.call(group: group), label: "Errors::Group #{group.id}")
      .and_return(Result.ok(vector))

    described_class.perform_now(group_id: group.id)

    group.reload
    expect(group.embedding.to_a).to eq(vector)
    expect(group.embedding_checksum).to eq(Errors::EmbeddingText.checksum(group: group))
    expect(group.embedded_at).to be_present
    expect(group.embedding_version).to eq(Ai::Constants::EMBEDDING_VERSION) # CYRA-168
  end

  it "è idempotente su checksum invariato" do
    group.update_columns(embedding: basis_vector(0),
                         embedding_checksum: Errors::EmbeddingText.checksum(group: group))
    expect(Embeddings::EmbedText).not_to receive(:call)

    described_class.perform_now(group_id: group.id)
  end

  it "gruppo sparito → no-op" do
    expect(Embeddings::EmbedText).not_to receive(:call)

    expect { described_class.perform_now(group_id: SecureRandom.uuid) }.not_to raise_error
  end

  it "errore del servizio → retry accodato, embedding intatto" do
    allow(Embeddings::EmbedText).to receive(:call)
      .and_return(Result.err(AppError.new("giù", code: "R502-AI-001", status: :bad_gateway)))

    expect { described_class.perform_now(group_id: group.id) }
      .to have_enqueued_job(described_class).with(group_id: group.id)
    expect(group.reload.embedding).to be_nil
  end
end
