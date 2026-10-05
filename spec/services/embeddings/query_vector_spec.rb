# frozen_string_literal: true

require "rails_helper"

RSpec.describe Embeddings::QueryVector do
  let(:vector) { Array.new(Ai::Constants::EMBEDDING_DIMENSIONS) { 0.1 } }
  let(:client) { instance_double(Ai::Embedding::Client) }

  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original
  end

  it "ritorna il vettore della query" do
    allow(client).to receive(:embed).and_return([ vector ])

    result = described_class.call(query: "come si fa il rollback?", client: client)

    expect(result).to be_ok
    expect(result.value).to eq(vector)
  end

  it "riusa la cache alla seconda richiesta della stessa query" do
    allow(client).to receive(:embed).and_return([ vector ])

    2.times { described_class.call(query: "come si fa il rollback?", client: client) }

    expect(client).to have_received(:embed).once
  end

  it "condivide la cache tra domini diversi: la query dei ticket serve anche la knowledge" do
    allow(client).to receive(:embed).and_return([ vector ])
    described_class.call(query: "rollback", client: client)

    Knowledge::SemanticSearch.call(scope: Knowledge::Page.all, query: "rollback", client: client)

    expect(client).to have_received(:embed).once
  end

  it "normalizza gli spazi ai bordi (stessa query, stessa chiave)" do
    allow(client).to receive(:embed).and_return([ vector ])

    described_class.call(query: "rollback", client: client)
    described_class.call(query: "  rollback  ", client: client)

    expect(client).to have_received(:embed).once
  end

  it "propaga l'errore e NON mette in cache quando il servizio è giù" do
    allow(client).to receive(:embed).and_raise(Ai::Embedding::Client::Error.new("giù", code: "R502-AI-004"))

    expect(described_class.call(query: "rollback", client: client)).to be_err
    expect(described_class.call(query: "rollback", client: client)).to be_err
    expect(client).to have_received(:embed).twice
  end
end
