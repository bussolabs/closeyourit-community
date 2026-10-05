# frozen_string_literal: true

require "rails_helper"

RSpec.describe Embeddings::Rerank do
  let(:client) { instance_double(Ai::Embedding::Client) }

  it "ritorna le posizioni pertinenti, ordinate dal cross-encoder" do
    allow(client).to receive(:rerank).and_return([ { index: 2, score: 0.8 }, { index: 0, score: 0.3 } ])

    result = described_class.call(query: "q", documents: %w[a b c], client: client)

    expect(result).to be_ok
    expect(result.value).to eq([ 2, 0 ])
  end

  it "taglia i candidati che il cross-encoder giudica non pertinenti (CYRA-553)" do
    allow(client).to receive(:rerank).and_return([ { index: 0, score: 0.002 } ])

    result = described_class.call(query: "asdlkj", documents: %w[a], client: client)

    expect(result).to be_ok
    expect(result.value).to eq([])
  end

  it "chiede il rerank col tetto di attesa corto: la ricerca è interattiva" do
    allow(client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])

    described_class.call(query: "q", documents: %w[a], client: client)

    expect(client).to have_received(:rerank).with(
      query: "q", documents: %w[a], read_timeout: Ai::Constants::RERANK_READ_TIMEOUT_SECONDS
    )
  end

  it "servizio giù → Result.err (il chiamante degrada all'ordine coseno, mai un errore utente)" do
    allow(client).to receive(:rerank)
      .and_raise(Ai::Embedding::Client::Error.new("timeout", code: "R504-AI-001", status: :gateway_timeout))

    result = described_class.call(query: "q", documents: %w[a], client: client)

    expect(result).to be_err
    expect(result.error.code).to eq("R504-AI-001")
  end

  it "configurazione embedding mancante → Result.err, mai un 500" do
    allow(client).to receive(:rerank).and_raise(KeyError.new("AI_API_KEY"))

    expect(described_class.call(query: "q", documents: %w[a], client: client)).to be_err
  end

  it "nessun documento → nessuna chiamata al servizio" do
    expect(client).not_to receive(:rerank)

    expect(described_class.call(query: "q", documents: [], client: client).value).to eq([])
  end
end
