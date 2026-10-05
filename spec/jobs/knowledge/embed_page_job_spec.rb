# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::EmbedPageJob, type: :job do
  let(:page) { create(:knowledge_page) }

  it "calcola e persiste embedding + checksum + embedded_at" do
    vector = basis_vector(0)
    allow(Embeddings::EmbedText).to receive(:call).and_return(Result.ok(vector))

    freeze_time do
      described_class.perform_now(page_id: page.id)
      page.reload
      expect(page.embedding.map(&:to_f)).to eq(vector)
      expect(page.embedding_checksum).to eq(Knowledge::EmbeddingText.checksum(page: page))
      expect(page.embedded_at).to eq(Time.current)
      expect(page.embedding_version).to eq(Ai::Constants::EMBEDDING_VERSION) # CYRA-168
    end
  end

  it "è idempotente: checksum invariato → nessuna nuova chiamata al servizio" do
    page.update_columns(embedding: basis_vector(0),
                        embedding_checksum: Knowledge::EmbeddingText.checksum(page: page))
    allow(Embeddings::EmbedText).to receive(:call)

    described_class.perform_now(page_id: page.id)
    expect(Embeddings::EmbedText).not_to have_received(:call)
  end

  it "pagina sparita → no-op silenzioso" do
    expect { described_class.perform_now(page_id: SecureRandom.uuid) }.not_to raise_error
  end

  it "errore del servizio → retry accodato (retry_on), embedding resta intatto" do
    allow(Embeddings::EmbedText).to receive(:call)
      .and_return(Result.err(AppError.new("giù", code: "R502-AI-001", status: :bad_gateway)))

    # Il raise interno è assorbito da retry_on (ApplicationJob): il job si ri-accoda da solo.
    expect { described_class.perform_now(page_id: page.id) }
      .to have_enqueued_job(described_class).with(page_id: page.id)
    expect(page.reload.embedding).to be_nil
  end
end
