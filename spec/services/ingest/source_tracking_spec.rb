# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — la registrazione della fonte osservata durante l'ingest (Errors/Metrics/Logs::Ingest::Record).
# È l'unica sorgente della card «strumenti di monitoraggio» del progetto: se qui si sbaglia il filo da
# leggere, un progetto che manda dati risulta senza nessuno strumento collegato.
RSpec.describe Ingest::SourceTracking, type: :service do
  let(:project) { create(:project) }
  # Il normalized dei Normalize è un oggetto immutabile: allo spec serve solo il contratto letto qui.
  let(:item) { Struct.new(:sdk_name, :sdk_version, :occurred_at, keyword_init: true) }

  describe ".track_one" do
    it "registra nome, versione e istante dell'evento" do
      normalized = item.new(sdk_name: "closeyourit-ruby", sdk_version: "1.2.3", occurred_at: 1.hour.ago)

      described_class.track_one(project: project, normalized: normalized)

      source = project.sources.sole
      expect(source.tool_code).to eq("closeyourit-ruby")
      expect(source.version).to eq("1.2.3")
    end

    it "senza nome dell'strumento non registra niente (l'identità del client manca)" do
      normalized = item.new(sdk_name: nil, sdk_version: "1.2.3", occurred_at: Time.current)

      described_class.track_one(project: project, normalized: normalized)

      expect(project.sources).to be_empty
    end
  end

  describe ".track_batch" do
    it "registra l'identità del client presa dal primo elemento che ce l'ha" do
      items = [ item.new(sdk_name: nil, sdk_version: nil, occurred_at: 2.hours.ago),
                item.new(sdk_name: "closeyourit-js", sdk_version: "2.0.0", occurred_at: 1.hour.ago) ]

      described_class.track_batch(project: project, items: items)

      source = project.sources.sole
      expect(source.tool_code).to eq("closeyourit-js")
      expect(source.version).to eq("2.0.0")
    end

    # L'attività del progetto è l'ultima volta che ha parlato: prendere il primo istante del blocco
    # farebbe sembrare fermo uno strumento che sta scrivendo adesso.
    it "l'ultima attività è l'istante PIÙ RECENTE del blocco, non quello del primo elemento" do
      recente = 1.minute.ago
      items = [ item.new(sdk_name: "closeyourit-js", sdk_version: "2.0.0", occurred_at: 3.hours.ago),
                item.new(sdk_name: "closeyourit-js", sdk_version: "2.0.0", occurred_at: recente) ]

      described_class.track_batch(project: project, items: items)

      expect(project.sources.sole.last_seen_at).to be_within(1.second).of(recente)
    end

    it "nessun elemento porta il nome dello strumento → non registra niente" do
      items = [ item.new(sdk_name: nil, sdk_version: nil, occurred_at: Time.current) ]

      described_class.track_batch(project: project, items: items)

      expect(project.sources).to be_empty
    end

    it "blocco vuoto → non registra niente e non solleva" do
      expect { described_class.track_batch(project: project, items: []) }.not_to raise_error
      expect(project.sources).to be_empty
    end

    # Elementi senza istante (payload incompleto) non devono far saltare il calcolo del massimo.
    it "elementi senza istante non rompono il calcolo dell'ultima attività" do
      recente = 5.minutes.ago
      items = [ item.new(sdk_name: "closeyourit-go", sdk_version: nil, occurred_at: nil),
                item.new(sdk_name: "closeyourit-go", sdk_version: nil, occurred_at: recente) ]

      expect { described_class.track_batch(project: project, items: items) }.not_to raise_error
      expect(project.sources.sole.last_seen_at).to be_within(1.second).of(recente)
    end
  end
end
