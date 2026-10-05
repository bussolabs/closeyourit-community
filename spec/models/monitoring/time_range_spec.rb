# frozen_string_literal: true

require "rails_helper"

RSpec.describe Monitoring::TimeRange do
  describe ".resolve" do
    it "senza parametri usa il periodo predefinito di ventiquattro ore" do
      range = described_class.resolve(key: nil)

      expect(range.key).to eq("24h")
      expect(range.from).to be_within(1.second).of(24.hours.ago)
      expect(range.to).to be_nil
    end

    it "accetta le quattro scelte rapide" do
      expect(described_class.resolve(key: "30m").from).to be_within(1.second).of(30.minutes.ago)
      expect(described_class.resolve(key: "24h").from).to be_within(1.second).of(24.hours.ago)
      expect(described_class.resolve(key: "7d").from).to be_within(1.second).of(7.days.ago)
      expect(described_class.resolve(key: "30d").from).to be_within(1.second).of(30.days.ago)
    end

    it "una chiave inventata ricade sul predefinito invece di far esplodere la pagina" do
      expect(described_class.resolve(key: "1000y").key).to eq("24h")
    end

    it "from/to presenti rendono il periodo personalizzato anche senza chiave" do
      range = described_class.resolve(key: nil, from: "2026-08-01T10:00", to: "2026-08-01T12:00")

      expect(range).to be_custom
      expect(range.from).to eq(Time.zone.parse("2026-08-01T10:00"))
      expect(range.to).to eq(Time.zone.parse("2026-08-01T12:00"))
    end

    it "from/to vincono sulla scelta rapida: è il drill-down dell'istogramma" do
      range = described_class.resolve(key: "7d", from: "2026-08-01T10:00", to: "2026-08-01T12:00")

      expect(range).to be_custom
      expect(range.from).to eq(Time.zone.parse("2026-08-01T10:00"))
    end

    it "un solo estremo lascia l'altro lato aperto" do
      range = described_class.resolve(key: "custom", from: "2026-08-01T10:00")

      expect(range).to be_custom
      expect(range.to).to be_nil
    end

    it "personalizzato senza estremi non filtra nulla" do
      range = described_class.resolve(key: "custom")

      expect(range).to be_custom
      expect(range.from).to be_nil
      expect(range.to).to be_nil
    end

    it "un estremo illeggibile vale come estremo assente, non come errore" do
      range = described_class.resolve(key: "custom", from: "non-una-data")

      expect(range.from).to be_nil
    end

    it "estremi invertiti si rimettono in ordine invece di restituire zero righe" do
      range = described_class.resolve(key: "custom", from: "2026-08-01T12:00", to: "2026-08-01T10:00")

      expect(range.from).to eq(Time.zone.parse("2026-08-01T10:00"))
      expect(range.to).to eq(Time.zone.parse("2026-08-01T12:00"))
    end
  end

  describe "#apply" do
    let(:project) { create(:project) }

    it "tiene solo i record dentro la finestra della scelta rapida" do
      recente = create(:log_entry, project:, occurred_at: 1.hour.ago)
      vecchio = create(:log_entry, project:, occurred_at: 48.hours.ago)

      risultato = described_class.resolve(key: "24h").apply(Logs::Entry.all, column: :occurred_at)

      expect(risultato).to include(recente)
      expect(risultato).not_to include(vecchio)
    end

    it "il periodo personalizzato è inclusivo su entrambi gli estremi" do
      from = 3.hours.ago
      to = 1.hour.ago
      dentro = create(:log_entry, project:, occurred_at: from)
      bordo = create(:log_entry, project:, occurred_at: to)
      fuori = create(:log_entry, project:, occurred_at: to + 1.second)

      risultato = described_class.resolve(key: "custom", from: from.iso8601(6), to: to.iso8601(6))
                                 .apply(Logs::Entry.all, column: :occurred_at)

      expect(risultato).to include(dentro, bordo)
      expect(risultato).not_to include(fuori)
    end

    it "senza estremi lascia lo scope intatto" do
      vecchio = create(:log_entry, project:, occurred_at: 3.years.ago)

      risultato = described_class.resolve(key: "custom").apply(Logs::Entry.all, column: :occurred_at)

      expect(risultato).to include(vecchio)
    end
  end

  describe "#link_params" do
    it "una scelta rapida viaggia come sola chiave" do
      expect(described_class.resolve(key: "7d").link_params).to eq({ range: "7d" })
    end

    it "il periodo personalizzato porta con sé gli estremi" do
      params = described_class.resolve(key: "custom", from: "2026-08-01T10:00").link_params

      expect(params[:range]).to eq("custom")
      expect(params[:from]).to eq(Time.zone.parse("2026-08-01T10:00").iso8601)
      expect(params).not_to have_key(:to)
    end
  end
end
