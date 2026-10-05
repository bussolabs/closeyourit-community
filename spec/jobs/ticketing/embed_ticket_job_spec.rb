# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::EmbedTicketJob do
  let(:ticket) { create(:ticket) }

  it "embedda il testo canonico e persiste vettore+checksum+timestamp" do
    vector = basis_vector(3)
    allow(Embeddings::EmbedText).to receive(:call)
      .with(text: Ticketing::EmbeddingText.call(ticket: ticket), label: "Ticketing::Ticket #{ticket.id}")
      .and_return(Result.ok(vector))

    described_class.perform_now(ticket_id: ticket.id)

    ticket.reload
    expect(ticket.embedding.to_a).to eq(vector)
    expect(ticket.embedding_checksum).to eq(Ticketing::EmbeddingText.checksum(ticket: ticket))
    expect(ticket.embedded_at).to be_present
    expect(ticket.embedding_version).to eq(Ai::Constants::EMBEDDING_VERSION) # CYRA-168
  end

  it "è idempotente: checksum invariato → nessuna chiamata al servizio" do
    ticket.update_columns(embedding: basis_vector(1),
                          embedding_checksum: Ticketing::EmbeddingText.checksum(ticket: ticket),
                          embedded_at: 1.hour.ago)
    expect(Embeddings::EmbedText).not_to receive(:call)

    described_class.perform_now(ticket_id: ticket.id)
  end

  it "re-embedda se il checksum è stale (testo cambiato dopo l'ultimo embed)" do
    ticket.update_columns(embedding: basis_vector(1), embedding_checksum: "stale", embedded_at: 1.hour.ago)
    allow(Embeddings::EmbedText).to receive(:call).and_return(Result.ok(basis_vector(2)))

    described_class.perform_now(ticket_id: ticket.id)

    expect(ticket.reload.embedding_checksum).to eq(Ticketing::EmbeddingText.checksum(ticket: ticket))
  end

  it "ticket sparito → no-op senza errori" do
    expect(Embeddings::EmbedText).not_to receive(:call)

    expect { described_class.perform_now(ticket_id: SecureRandom.uuid) }.not_to raise_error
  end

  it "errore del servizio → retry accodato (retry_on), embedding resta intatto" do
    allow(Embeddings::EmbedText).to receive(:call)
      .and_return(Result.err(AppError.new("giù", code: "R502-AI-001", status: :bad_gateway)))

    # Il raise interno è assorbito da retry_on (ApplicationJob): il job si ri-accoda da solo.
    expect { described_class.perform_now(ticket_id: ticket.id) }
      .to have_enqueued_job(described_class).with(ticket_id: ticket.id)
    expect(ticket.reload.embedding).to be_nil
  end
end
