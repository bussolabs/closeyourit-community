# frozen_string_literal: true

require "rails_helper"

# Il calendario dei rilasci di endoflife.date. Due cose vanno tenute ferme: un prodotto che il
# calendario NON conosce non è un guasto (Flutter e Dart non ci sono), e una risposta è uguale per
# tutti i progetti — quindi si chiede una volta al giorno, non una volta per progetto.
RSpec.describe Vulnerabilities::Eol::Client do
  subject(:client) { described_class.new(base_url: "https://eol.test") }

  def ruby_url = "https://eol.test/api/ruby.json"

  let(:cycles) { [ { "cycle" => "3.4", "eol" => "2028-03-31", "latest" => "3.4.10" } ] }

  it "ritorna i cicli di rilascio del prodotto" do
    stub_request(:get, ruby_url).to_return(status: 200, body: cycles.to_json)

    expect(client.cycles("ruby")).to eq(cycles)
  end

  it "chiede JSON e non si aspetta HTML" do
    request = stub_request(:get, ruby_url)
              .with(headers: { "Accept" => "application/json" })
              .to_return(status: 200, body: cycles.to_json)

    client.cycles("ruby")

    expect(request).to have_been_requested
  end

  it "un prodotto sconosciuto non è un errore: nessun dato, nessun allarme" do
    stub_request(:get, "https://eol.test/api/flutter.json").to_return(status: 404, body: "")

    expect(client.cycles("flutter")).to be_nil
  end

  it "un nome con caratteri speciali non sfonda l'indirizzo" do
    request = stub_request(:get, "https://eol.test/api/dotnet%2Fcore.json")
              .to_return(status: 200, body: "[]")

    client.cycles("dotnet/core")

    expect(request).to have_been_requested
  end

  it "un 500 diventa un errore di dominio, non una risposta vuota scambiata per «tutto a posto»" do
    stub_request(:get, ruby_url).to_return(status: 500, body: "")

    expect { client.cycles("ruby") }
      .to raise_error(described_class::Error) { |error| expect(error.code).to eq("R502-EOL-001") }
  end

  it "il servizio irraggiungibile diventa un errore di dominio, non un'eccezione di rete che sfugge" do
    stub_request(:get, ruby_url).to_raise(SocketError)

    expect { client.cycles("ruby") }
      .to raise_error(described_class::Error) { |error| expect(error.code).to eq("R502-EOL-001") }
  end

  it "il timeout diventa un errore di dominio" do
    stub_request(:get, ruby_url).to_timeout

    expect { client.cycles("ruby") }
      .to raise_error(described_class::Error) { |error| expect(error.code).to eq("R502-EOL-001") }
  end

  it "un corpo che non è JSON è un errore di contratto, con un codice suo" do
    stub_request(:get, ruby_url).to_return(status: 200, body: "<html>manutenzione</html>")

    expect { client.cycles("ruby") }
      .to raise_error(described_class::Error) { |error| expect(error.code).to eq("R502-EOL-002") }
  end

  it "un JSON valido ma di forma sbagliata vale come «non so»" do
    stub_request(:get, ruby_url).to_return(status: 200, body: { "error" => "nope" }.to_json)

    expect(client.cycles("ruby")).to be_nil
  end

  # La cache di test non tiene niente (null_store): senza una cache vera qui la seconda chiamata
  # ripartirebbe comunque e la prova non direbbe nulla.
  describe "la cache" do
    before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

    it "dieci progetti sullo stesso linguaggio fanno UNA richiesta sola" do
      request = stub_request(:get, ruby_url).to_return(status: 200, body: cycles.to_json)

      10.times { client.cycles("ruby") }

      expect(request).to have_been_requested.once
    end

    it "prodotti diversi non si sovrascrivono a vicenda" do
      stub_request(:get, ruby_url).to_return(status: 200, body: cycles.to_json)
      stub_request(:get, "https://eol.test/api/nodejs.json")
        .to_return(status: 200, body: [ { "cycle" => "24" } ].to_json)

      expect(client.cycles("ruby")).to eq(cycles)
      expect(client.cycles("nodejs")).to eq([ { "cycle" => "24" } ])
    end

    it "anche il «prodotto sconosciuto» si ricorda: non si ritenta a ogni giro" do
      request = stub_request(:get, "https://eol.test/api/flutter.json").to_return(status: 404, body: "")

      3.times { expect(client.cycles("flutter")).to be_nil }

      expect(request).to have_been_requested.once
    end

    it "scaduto il giorno si richiede da capo" do
      request = stub_request(:get, ruby_url).to_return(status: 200, body: cycles.to_json)

      client.cycles("ruby")
      travel_to(described_class::CACHE_TTL.from_now + 1.minute) { client.cycles("ruby") }

      expect(request).to have_been_requested.twice
    end
  end
end
