# frozen_string_literal: true

require "rails_helper"

# CYRA-943 — the embedding that groups the requests saying the same thing.
RSpec.describe Helpdesk::EmbedRequestJob, type: :job do
  let(:request_record) { create(:helpdesk_request, body: "The checkout fails.", email: "anna@example.com") }

  it "embeds what the visitor wrote, never the address" do
    allow(Embeddings::EmbedText).to receive(:call).and_return(Result.ok(basis_vector(0)))

    described_class.perform_now(request_id: request_record.id)

    expect(Embeddings::EmbedText).to have_received(:call).with(hash_including(text: "The checkout fails."))
    expect(request_record.reload).to have_attributes(embedding_checksum: Helpdesk::EmbeddingText.checksum(request: request_record),
                                                     embedding_version: Ai::Configuration.current.embedding_version)
    expect(request_record.embedding.map(&:to_f)).to eq(basis_vector(0))
  end

  it "does nothing when the embedding is current" do
    request_record.update_columns(embedding: basis_vector(0), embedding_checksum: Helpdesk::EmbeddingText.checksum(request: request_record))
    allow(Embeddings::EmbedText).to receive(:call)

    described_class.perform_now(request_id: request_record.id)

    expect(Embeddings::EmbedText).not_to have_received(:call)
  end

  it "ignores a request that is gone" do
    expect { described_class.perform_now(request_id: SecureRandom.uuid) }.not_to raise_error
  end

  describe "queueing on arrival" do
    let(:project) { create(:project, helpdesk_enabled: true) }

    it "queues the embedding only when the installation has embeddings configured" do
      snapshot = Ai::Configuration.current
      allow(Ai::Configuration).to receive(:current).and_return(snapshot.with(embed_base_url: nil))
      expect { Helpdesk::ReceiveRequest.call(project: project, message: "Hello") }.not_to have_enqueued_job(described_class)

      allow(Ai::Configuration).to receive(:current).and_return(snapshot.with(embed_base_url: "https://embed.test/v1"))
      expect { Helpdesk::ReceiveRequest.call(project: project, message: "Hello") }.to have_enqueued_job(described_class)
    end
  end
end
