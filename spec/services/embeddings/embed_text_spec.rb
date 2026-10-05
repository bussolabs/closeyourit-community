# frozen_string_literal: true

require "rails_helper"

RSpec.describe Embeddings::EmbedText do
  let(:client) { instance_double(Ai::Embedding::Client) }

  it "ritorna il vettore a 1024 dimensioni" do
    vector = basis_vector(0)
    allow(client).to receive(:embed).with(input: "ciao").and_return([ vector ])

    result = described_class.call(text: "ciao", client: client)

    expect(result).to be_ok
    expect(result.value).to eq(vector)
  end

  it "strippa il testo e lo clampa a EMBED_MAX_CHARS prima dell'embed" do
    long_text = "a" * (Ai::Constants::EMBED_MAX_CHARS + 500)
    allow(client).to receive(:embed).with(input: "a" * Ai::Constants::EMBED_MAX_CHARS)
                                    .and_return([ basis_vector(0) ])

    expect(described_class.call(text: "  #{long_text}  ", client: client)).to be_ok
  end

  it "logga il taglio con la label del chiamante: il troncamento non è mai silenzioso" do
    long_text = "a" * (Ai::Constants::EMBED_MAX_CHARS + 500)
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(Rails.logger).to receive(:warn)

    described_class.call(text: long_text, label: "Knowledge::Page abc", client: client)

    expect(Rails.logger).to have_received(:warn)
      .with(a_string_including("Knowledge::Page abc", (Ai::Constants::EMBED_MAX_CHARS + 500).to_s))
  end

  it "non logga nulla quando il testo sta nel budget" do
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(Rails.logger).to receive(:warn)

    described_class.call(text: "a" * Ai::Constants::EMBED_MAX_CHARS, client: client)

    expect(Rails.logger).not_to have_received(:warn)
  end

  it "testo blank → R422-AI-002 senza chiamare il client" do
    expect(client).not_to receive(:embed)

    result = described_class.call(text: "   ", client: client)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-AI-002")
  end

  it "dimensione inattesa → R502-AI-005" do
    allow(client).to receive(:embed).and_return([ [ 0.1, 0.2 ] ])

    result = described_class.call(text: "ciao", client: client)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-AI-005")
  end

  it "errore del client → Result.err con codice e status del client" do
    allow(client).to receive(:embed)
      .and_raise(Ai::Embedding::Client::Error.new("timeout", code: "R504-AI-001", status: :gateway_timeout))

    result = described_class.call(text: "ciao", client: client)

    expect(result).to be_err
    expect(result.error.code).to eq("R504-AI-001")
    expect(result.error.status).to eq(:gateway_timeout)
  end

  it "ENV mancante (KeyError alla costruzione del client) → R502-AI-002, mai eccezione" do
    original = ENV.delete("AI_API_KEY")
    begin
      result = described_class.call(text: "ciao")

      expect(result).to be_err
      expect(result.error.code).to eq("R502-AI-002")
    ensure
      ENV["AI_API_KEY"] = original if original
    end
  end
end
