# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vulnerabilities::Osv::Client do
  subject(:client) { described_class.new(base_url: "https://osv.test") }

  def batch_url = "https://osv.test/v1/querybatch"

  describe "#query_batch" do
    it "spedisce le coordinate nel formato OSV e ritorna gli id per posizione" do
      request = stub_request(:post, batch_url)
                .with(body: {
                        queries: [
                          { package: { name: "rails", ecosystem: "RubyGems" }, version: "7.0.0" },
                          { package: { name: "lodash", ecosystem: "npm" }, version: "4.17.21" }
                        ]
                      })
                .to_return(status: 200, body: {
                  results: [ { vulns: [ { id: "GHSA-1" }, { id: "GHSA-2" } ] }, {} ]
                }.to_json)

      result = client.query_batch([
                                    { ecosystem: "RubyGems", name: "rails", version: "7.0.0" },
                                    { ecosystem: "npm", name: "lodash", version: "4.17.21" }
                                  ])

      expect(result).to eq([ %w[GHSA-1 GHSA-2], [] ])
      expect(request).to have_been_requested
    end

    it "una lista vuota non genera nessuna richiesta" do
      expect(client.query_batch([])).to eq([])
      expect(a_request(:post, batch_url)).not_to have_been_made
    end

    it "risultati disallineati sono un errore, non un'attribuzione a caso" do
      stub_request(:post, batch_url).to_return(status: 200, body: { results: [ {} ] }.to_json)

      expect do
        client.query_batch([
                             { ecosystem: "RubyGems", name: "a", version: "1" },
                             { ecosystem: "RubyGems", name: "b", version: "1" }
                           ])
      end.to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-OSV-002") }
    end

    it "un 500 diventa Error R502, non un risultato vuoto" do
      stub_request(:post, batch_url).to_return(status: 500, body: "")

      expect { client.query_batch([ { ecosystem: "npm", name: "a", version: "1" } ]) }
        .to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-OSV-001") }
    end

    it "il timeout diventa Error, non un'eccezione di rete che sfugge" do
      stub_request(:post, batch_url).to_timeout

      expect { client.query_batch([ { ecosystem: "npm", name: "a", version: "1" } ]) }
        .to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-OSV-001") }
    end

    it "un corpo non JSON è un errore di contratto" do
      stub_request(:post, batch_url).to_return(status: 200, body: "<html>maintenance</html>")

      expect { client.query_batch([ { ecosystem: "npm", name: "a", version: "1" } ]) }
        .to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-OSV-002") }
    end
  end

  describe "#vulnerability" do
    it "legge il record completo per id" do
      stub_request(:get, "https://osv.test/v1/vulns/GHSA-9822-6m93-xqf4")
        .to_return(status: 200, body: { id: "GHSA-9822-6m93-xqf4", summary: "XSS" }.to_json)

      expect(client.vulnerability("GHSA-9822-6m93-xqf4")["summary"]).to eq("XSS")
    end

    it "un advisory ritirato fra il batch e la lettura dà nil, non un errore" do
      stub_request(:get, "https://osv.test/v1/vulns/GHSA-sparito")
        .to_return(status: 404, body: { message: "not found" }.to_json)

      expect(client.vulnerability("GHSA-sparito")).to be_nil
    end
  end
end
