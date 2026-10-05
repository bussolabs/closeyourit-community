# frozen_string_literal: true

require "rails_helper"

RSpec.describe Changelog::Filter do
  let(:releases) do
    [
      Changelog::Release.new(
        version: "0.2.0", date: "2026-07-02",
        sections: [
          { label: "Added", items: [
            "**Gruppi di controlli**: i siti si raggruppano. [Disponibilità](/member/monitoring/monitors)",
            "**Etichette sui ticket**: si filtrano. [Ticket](/member/tickets)"
          ] },
          { label: "Fixed", items: [ "**Grafico storto**: raddrizzato. [Server](/member/monitoring/servers)" ] }
        ]
      ),
      Changelog::Release.new(
        version: "0.1.0", date: "2026-07-01",
        sections: [
          { label: "Changed", items: [ "**Novità senza area**: nessun rimando qui dentro." ] }
        ]
      )
    ]
  end

  def versions(result) = result.map(&:version)

  describe "senza filtri" do
    it "restituisce tutte le release così come sono" do
      expect(described_class.call(releases)).to eq(releases)
    end
  end

  describe "filtro per area" do
    subject(:result) { described_class.call(releases, area: [ "uptime" ]) }

    it "tiene solo le voci dell'area chiesta" do
      expect(versions(result)).to eq(%w[0.2.0])
      expect(result.first.sections.flat_map { |s| s[:items] }.size).to eq(1)
      expect(result.first.sections.first[:items].first).to include("Gruppi di controlli")
    end

    it "scarta le sezioni rimaste senza voci" do
      expect(result.first.sections.map { |s| s[:label] }).to eq(%w[Added])
    end

    it "accetta più aree insieme" do
      due = described_class.call(releases, area: %w[uptime servers])

      expect(due.first.sections.map { |s| s[:label] }).to eq(%w[Added Fixed])
    end

    it "ignora un'area sconosciuta invece di svuotare la pagina" do
      expect(described_class.call(releases, area: [ "inventata" ])).to eq(releases)
    end
  end

  describe "filtro per tipo di modifica" do
    it "tiene solo le sezioni del tipo chiesto" do
      result = described_class.call(releases, kind: [ "fixed" ])

      expect(versions(result)).to eq(%w[0.2.0])
      expect(result.first.sections.map { |s| s[:label] }).to eq(%w[Fixed])
    end

    it "accetta più tipi insieme" do
      result = described_class.call(releases, kind: %w[fixed changed])

      expect(versions(result)).to eq(%w[0.2.0 0.1.0])
    end

    it "ignora un tipo sconosciuto" do
      expect(described_class.call(releases, kind: [ "inventato" ])).to eq(releases)
    end
  end

  describe "ricerca nel testo delle voci" do
    it "trova la voce che contiene le parole cercate" do
      result = described_class.call(releases, query: "etichette")

      expect(versions(result)).to eq(%w[0.2.0])
      expect(result.first.sections.flat_map { |s| s[:items] }.size).to eq(1)
    end

    it "non distingue maiuscole e accenti" do
      expect(versions(described_class.call(releases, query: "NOVITA"))).to eq(%w[0.1.0])
    end

    it "cerca anche nel nome dell'area, non nella parola scritta nel file" do
      # La voce dice «Disponibilità»: chi cerca il nome del menu la trova lo stesso.
      expect(versions(described_class.call(releases, query: "Uptime"))).to eq(%w[0.2.0])
    end

    it "non cerca dentro gli indirizzi delle pagine" do
      expect(described_class.call(releases, query: "member/monitoring")).to be_empty
    end

    it "restituisce vuoto quando non trova niente" do
      expect(described_class.call(releases, query: "parolachenonesiste")).to be_empty
    end
  end

  describe "filtri combinati" do
    it "applica area, tipo e ricerca insieme" do
      result = described_class.call(releases, area: [ "servers" ], kind: [ "fixed" ], query: "grafico")

      expect(versions(result)).to eq(%w[0.2.0])
      expect(result.first.sections.first[:items].first).to include("Grafico storto")
    end

    it "restituisce vuoto quando i filtri non si incontrano" do
      expect(described_class.call(releases, area: [ "tickets" ], kind: [ "fixed" ])).to be_empty
    end
  end

  describe "KINDS" do
    it "elenca i tipi di modifica nell'ordine in cui si leggono" do
      expect(described_class::KINDS).to eq(%w[added changed fixed removed deprecated security])
    end
  end
end
