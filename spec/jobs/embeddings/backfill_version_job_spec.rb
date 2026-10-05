# frozen_string_literal: true

require "rails_helper"

RSpec.describe Embeddings::BackfillVersionJob do
  it "stampa la versione corrente sulle righe embeddate che ne sono prive, sulle 3 tabelle" do
    page = create(:knowledge_page)
    page.update_columns(embedding: basis_vector(0), embedding_checksum: "x", embedded_at: Time.current,
                        embedding_version: nil)
    group = create(:error_group)
    group.update_columns(embedding: basis_vector(0), embedding_version: nil)
    ticket = create(:ticket)
    ticket.update_columns(embedding: basis_vector(0), embedding_version: nil)

    described_class.perform_now

    expect(page.reload.embedding_version).to eq(Ai::Constants::EMBEDDING_VERSION)
    expect(group.reload.embedding_version).to eq(Ai::Constants::EMBEDDING_VERSION)
    expect(ticket.reload.embedding_version).to eq(Ai::Constants::EMBEDDING_VERSION)
  end

  it "non tocca le righe senza embedding né quelle di un'altra versione" do
    blank = create(:knowledge_page) # nessun embedding → resta nil
    other_version = create(:error_group)
    other_version.update_columns(embedding: basis_vector(0), embedding_version: "qwen3-emb-0.6b-1024-v0")

    described_class.perform_now

    expect(blank.reload.embedding_version).to be_nil
    expect(other_version.reload.embedding_version).to eq("qwen3-emb-0.6b-1024-v0")
  end

  it "è idempotente: una seconda esecuzione non cambia nulla" do
    ticket = create(:ticket)
    ticket.update_columns(embedding: basis_vector(0), embedding_version: nil)
    described_class.perform_now

    expect { described_class.perform_now }.not_to(change { ticket.reload.embedding_version })
  end
end
