# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Embedding::Client do
  # Base URL col prefisso /v1 come in produzione (LiteLLM, CYRA-758): le spec provano anche che il
  # prefisso non venga perso componendo i path.
  subject(:client) { described_class.new(api_key: "embed-key", base_url: "https://embed.test/v1") }

  let(:embed_url) { "https://embed.test/v1/embeddings" }
  let(:rerank_url) { "https://embed.test/v1/rerank" }
  let(:vector) { [ 0.1, 0.2, 0.3 ] }

  describe "#embed" do
    it "POSTa con Bearer e ritorna i vettori nell'ordine degli index" do
      post = stub_request(:post, embed_url)
             .with(headers: { "Authorization" => "Bearer embed-key" },
                   body: hash_including("model" => Ai::Constants::EMBEDDING_MODEL, "input" => [ "ciao" ]))
             .to_return(status: 200, body: { "data" => [ { "index" => 0, "embedding" => vector } ] }.to_json)

      expect(client.embed(input: "ciao")).to eq([ vector ])
      expect(post).to have_been_requested
    end

    it "riordina per index una risposta batch fuori ordine" do
      stub_request(:post, embed_url).to_return(
        status: 200,
        body: { "data" => [ { "index" => 1, "embedding" => [ 2.0 ] }, { "index" => 0, "embedding" => [ 1.0 ] } ] }.to_json
      )

      expect(client.embed(input: [ "a", "b" ])).to eq([ [ 1.0 ], [ 2.0 ] ])
    end

    it "mappa 401 a R502-AI-002" do
      stub_request(:post, embed_url).to_return(status: 401, body: "{}")
      expect { client.embed(input: "x") }.to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-AI-002") }
    end

    it "mappa 500 upstream a R502-AI-001" do
      stub_request(:post, embed_url).to_return(status: 500, body: "{}")
      expect { client.embed(input: "x") }.to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-AI-001") }
    end

    it "mappa il timeout a R504-AI-001 con status gateway_timeout" do
      stub_request(:post, embed_url).to_timeout
      expect { client.embed(input: "x") }.to raise_error(described_class::Error) { |e|
        expect(e.code).to eq("R504-AI-001")
        expect(e.status).to eq(:gateway_timeout)
      }
    end

    it "mappa la connessione rifiutata (servizio giù) a R502-AI-001" do
      stub_request(:post, embed_url).to_raise(Errno::ECONNREFUSED)
      expect { client.embed(input: "x") }.to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-AI-001") }
    end

    it "mappa reset, chiusura a metà e TLS rotto a R502-AI-001: il degrado, non un 500 (CYRA-758)" do
      [ Errno::ECONNRESET, Errno::ENETUNREACH, Errno::ECONNABORTED, Errno::EPIPE, Errno::ETIMEDOUT, EOFError, IOError,
        OpenSSL::SSL::SSLError ].each do |klass|
        stub_request(:post, embed_url).to_raise(klass)
        expect { client.embed(input: "x") }.to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-AI-001") }
      end
    end

    it "mappa il body non parsabile a R502-AI-003" do
      stub_request(:post, embed_url).to_return(status: 200, body: "not-json")
      expect { client.embed(input: "x") }.to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-AI-003") }
    end

    it "mappa la risposta senza embedding a R502-AI-005" do
      stub_request(:post, embed_url).to_return(status: 200, body: { "data" => [ { "index" => 0 } ] }.to_json)
      expect { client.embed(input: "x") }.to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-AI-005") }
    end

    it "mappa la risposta con data vuota a R502-AI-005" do
      stub_request(:post, embed_url).to_return(status: 200, body: { "data" => [] }.to_json)
      expect { client.embed(input: "x") }.to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-AI-005") }
    end
  end

  describe "#rerank" do
    around do |example|
      previous = ENV["EMBED_RERANK_MODEL"]
      ENV["EMBED_RERANK_MODEL"] = "rerank"
      example.run
    ensure
      ENV["EMBED_RERANK_MODEL"] = previous
    end

    it "senza alias configurato solleva R503-AI-002 senza toccare la rete (CYRA-758)" do
      ENV.delete("EMBED_RERANK_MODEL")

      expect { client.rerank(query: "q", documents: [ "d" ]) }
        .to raise_error(described_class::Error) { |e|
          expect(e.code).to eq("R503-AI-002")
          expect(e.status).to eq(:service_unavailable)
        }
      expect(a_request(:post, rerank_url)).not_to have_been_made
    end

    it "POSTa query+documents e ritorna index/score ordinati per score decrescente" do
      post = stub_request(:post, rerank_url)
             .with(headers: { "Authorization" => "Bearer embed-key" },
                   body: hash_including("model" => "rerank", "query" => "q",
                                        "documents" => [ "d1", "d2" ]))
             .to_return(status: 200, body: {
               "results" => [ { "index" => 0, "relevance_score" => 0.2 }, { "index" => 1, "relevance_score" => 0.9 } ]
             }.to_json)

      expect(client.rerank(query: "q", documents: [ "d1", "d2" ])).to eq(
        [ { index: 1, score: 0.9 }, { index: 0, score: 0.2 } ]
      )
      expect(post).to have_been_requested
    end

    it "mappa la risposta senza results a R502-AI-005" do
      stub_request(:post, rerank_url).to_return(status: 200, body: { "results" => [] }.to_json)
      expect { client.rerank(query: "q", documents: [ "d" ]) }
        .to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-AI-005") }
    end

    it "mappa 502 upstream a R502-AI-001" do
      stub_request(:post, rerank_url).to_return(status: 502, body: "{}")
      expect { client.rerank(query: "q", documents: [ "d" ]) }
        .to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-AI-001") }
    end

    it "applica il tetto di attesa passato dal chiamante (CYRA-553)" do
      http = Net::HTTP.new("embed.test", 443)
      allow(Net::HTTP).to receive(:new).and_return(http)
      stub_request(:post, rerank_url)
        .to_return(status: 200, body: { "results" => [ { "index" => 0, "relevance_score" => 0.9 } ] }.to_json)

      client.rerank(query: "q", documents: [ "d" ], read_timeout: 4)

      expect(http.read_timeout).to eq(4)
    end

    it "senza tetto esplicito resta quello lungo dell'embed (il RAG in coda non ha fretta)" do
      http = Net::HTTP.new("embed.test", 443)
      allow(Net::HTTP).to receive(:new).and_return(http)
      stub_request(:post, rerank_url)
        .to_return(status: 200, body: { "results" => [ { "index" => 0, "relevance_score" => 0.9 } ] }.to_json)

      client.rerank(query: "q", documents: [ "d" ])

      expect(http.read_timeout).to eq(Ai::Constants::EMBED_READ_TIMEOUT_SECONDS)
    end
  end
end
