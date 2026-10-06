# frozen_string_literal: true

require "rails_helper"

# ── CYRA-625 ──────────────────────────────────────────────────────────────────────────────────────
#
# Lo scaffale pubblico guardato da fuori, come farebbe chi installa. Qui si prova l'indirizzo DAVVERO
# interrogato e la lettura del puntatore che il registro dichiara — non un massimo ricalcolato da
# noi, che vorrebbe dire sostituire la parola del registro con la nostra.
RSpec.describe Agents::Registries::Client do
  describe "l'alfabeto del nome, prima che parta qualunque chiamata" do
    # Un nome che è a sua volta un indirizzo è il caso peggiore: la composizione di indirizzi usata
    # dagli altri client di questo repository, quando il secondo pezzo è assoluto, butta via
    # l'indirizzo di partenza e chiama l'host scritto dentro il nome.
    cattivi = [ "../altro", "%2e%2e%2fatro", "con spazio", "due:punti", "/assoluto", "//due",
                "https://evil.example.com/pacchetto", "a\nb" ]

    %w[npm pub rubygems pypi].each do |family|
      cattivi.each do |nome|
        it "#{family}: rifiuta #{nome.inspect} senza chiamare nessuno" do
          client = described_class.for(family)

          expect { client.lookup(nome, "1.0.0") }
            .to raise_error(described_class::Error) { |e| expect(e.code).to eq("R422-REGISTRY-001") }
          expect(WebMock).not_to have_requested(:get, //)
        end
      end

      it "#{family}: rifiuta una versione fuori alfabeto senza chiamare nessuno" do
        client = described_class.for(family)

        expect { client.lookup("pacchetto", "1.0.0/../../x") }
          .to raise_error(described_class::Error) { |e| expect(e.code).to eq("R422-REGISTRY-001") }
        expect(WebMock).not_to have_requested(:get, //)
      end
    end
  end

  describe "npm" do
    let(:client) { described_class.for("npm") }
    let(:url) { "https://registry.npmjs.org/%40closeyourit%2Fcli" }

    it "legge presenza, puntatore dichiarato e codice di costruzione dall'indirizzo vero" do
      stub_request(:get, url).to_return(
        status: 200,
        body: { "dist-tags" => { "latest" => "0.11.0" },
                "versions" => { "0.11.0" => { "gitHead" => "a" * 40 } } }.to_json
      )

      esito = client.lookup("@closeyourit/cli", "0.11.0")

      expect(esito).to include(present: true, yanked: false, latest: "0.11.0",
                               sha: "a" * 40, url: url)
    end

    it "un pacchetto che non esiste è «non ancora», non un errore" do
      stub_request(:get, url).to_return(status: 404, body: "")

      expect(client.lookup("@closeyourit/cli", "0.11.0")).to include(present: false)
    end

    it "un corpo illeggibile è una linea storta, non una negazione" do
      stub_request(:get, url).to_return(status: 200, body: "non json")

      expect { client.lookup("@closeyourit/cli", "0.11.0") }
        .to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-REGISTRY-002") }
    end

    it "«troppe richieste» ha un codice suo" do
      stub_request(:get, url).to_return(status: 429, body: "")

      expect { client.lookup("@closeyourit/cli", "0.11.0") }
        .to raise_error(described_class::Error) { |e| expect(e.code).to eq("R502-REGISTRY-003") }
    end
  end

  # CYRA-1034 — the latest release only, from the small `/latest` document.
  describe "npm latest" do
    let(:client) { described_class.for("npm") }

    it "reads the latest published version" do
      stub_request(:get, "https://registry.npmjs.org/%40openai%2Fcodex/latest")
        .to_return(status: 200, body: { "version" => "0.160.1" }.to_json)

      expect(client.latest("@openai/codex")).to eq("0.160.1")
    end

    it "gives nothing for a package that does not exist" do
      stub_request(:get, "https://registry.npmjs.org/no-such-package/latest").to_return(status: 404, body: "")

      expect(client.latest("no-such-package")).to be_nil
    end

    it "refuses a name outside the alphabet without calling anyone" do
      expect { client.latest("../evil") }
        .to raise_error(described_class::Error) { |e| expect(e.code).to eq("R422-REGISTRY-001") }
    end
  end

  describe "pub.dev" do
    let(:client) { described_class.for("pub") }
    let(:url) { "https://pub.dev/api/packages/closeyourit" }

    it "legge il puntatore dichiarato e il ritiro della singola versione" do
      stub_request(:get, url).to_return(
        status: 200,
        body: { "latest" => { "version" => "0.11.0" },
                "versions" => [ { "version" => "0.11.0", "retracted" => true } ] }.to_json
      )

      expect(client.lookup("closeyourit", "0.11.0"))
        .to include(present: true, yanked: true, latest: "0.11.0", url: url)
    end
  end

  describe "RubyGems" do
    let(:client) { described_class.for("rubygems") }
    let(:versione_url) { "https://rubygems.org/api/v2/rubygems/closeyourit/versions/0.11.0.json" }
    let(:ultima_url) { "https://rubygems.org/api/v1/versions/closeyourit/latest.json" }

    # Il ritiro lo dichiara la risposta per singola versione: dedurlo dall'elenco vorrebbe dire
    # inventarlo, perché una versione ritirata nell'elenco resta.
    it "legge il ritiro dalla risposta per singola versione e il puntatore dalla risposta «ultima»" do
      stub_request(:get, versione_url).to_return(status: 200, body: { "yanked" => true }.to_json)
      stub_request(:get, ultima_url).to_return(status: 200, body: { "version" => "0.10.0" }.to_json)

      expect(client.lookup("closeyourit", "0.11.0"))
        .to include(present: true, yanked: true, latest: "0.10.0", url: versione_url)
    end
  end

  describe "PyPI" do
    let(:client) { described_class.for("pypi") }
    let(:versione_url) { "https://pypi.org/pypi/closeyourit/0.11.0/json" }
    let(:progetto_url) { "https://pypi.org/pypi/closeyourit/json" }

    it "legge il puntatore da info.version del progetto" do
      stub_request(:get, versione_url).to_return(status: 200, body: { "info" => { "yanked" => false } }.to_json)
      stub_request(:get, progetto_url).to_return(status: 200, body: { "info" => { "version" => "0.11.0" } }.to_json)

      expect(client.lookup("closeyourit", "0.11.0"))
        .to include(present: true, yanked: false, latest: "0.11.0", url: versione_url)
    end

    it "la versione che non esiste ancora è la risposta normale finché la pubblicazione non arriva" do
      stub_request(:get, versione_url).to_return(status: 404, body: "")
      stub_request(:get, progetto_url).to_return(status: 200, body: { "info" => { "version" => "0.10.0" } }.to_json)

      expect(client.lookup("closeyourit", "0.11.0")).to include(present: false, latest: "0.10.0")
    end
  end
end
