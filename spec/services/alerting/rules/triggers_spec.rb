# frozen_string_literal: true

require "rails_helper"

# CYRA-490 — lo storico degli scatti di una regola. I conteggi restano allineati alla tabella (righe di
# notifica, come l'index), mentre l'elenco recente fonde le consegne di UNO stesso scatto (più
# destinatari, più canali) in una sola voce, così la timeline resta leggibile.
RSpec.describe Alerting::Rules::Triggers, type: :service do
  let(:organization) { create(:organization) }
  let(:rule) { create(:alerting_rule, organization:) }

  describe ".stats" do
    it "conta gli avvisi nelle finestre 24h/7g, il totale e l'ultimo" do
      create(:alerting_notification, rule:, organization:, created_at: 2.hours.ago)
      create(:alerting_notification, rule:, organization:, created_at: 3.days.ago)
      create(:alerting_notification, rule:, organization:, created_at: 20.days.ago)

      stats = described_class.stats(rule)

      expect(stats.total).to eq(3)
      expect(stats.last_24h).to eq(1)
      expect(stats.last_7d).to eq(2)
      expect(stats.last_at).to be_within(1.minute).of(2.hours.ago)
    end

    it "è a zero e senza ultimo scatto quando la regola non è mai scattata" do
      stats = described_class.stats(rule)

      expect(stats.total).to eq(0)
      expect(stats.last_24h).to eq(0)
      expect(stats.last_at).to be_nil
    end
  end

  describe ".recent" do
    it "fonde le consegne dello stesso scatto in una voce con più canali" do
      group = create(:error_group)
      at = 1.hour.ago
      create(:alerting_notification, rule:, organization:, subject: group, via: :in_app,
                                     created_at: at, title: "Nuovo errore · Boom")
      create(:alerting_notification, rule:, organization:, subject: group, via: :email,
                                     created_at: at, title: "Nuovo errore · Boom")

      recent = described_class.recent(rule)

      expect(recent.size).to eq(1)
      expect(recent.first.title).to eq("Nuovo errore · Boom")
      expect(recent.first.channels).to match_array(%w[in_app email])
    end

    it "tiene distinti gli scatti dello stesso soggetto in finestre temporali diverse" do
      group = create(:error_group)
      create(:alerting_notification, rule:, organization:, subject: group, created_at: 10.minutes.ago)
      create(:alerting_notification, rule:, organization:, subject: group, created_at: 5.days.ago)

      expect(described_class.recent(rule).size).to eq(2)
    end

    it "ordina dal più recente e rispetta il limite" do
      group = create(:error_group)
      create(:alerting_notification, rule:, organization:, subject: group, created_at: 1.day.ago, title: "Vecchio")
      create(:alerting_notification, rule:, organization:, subject: group, created_at: 1.minute.ago, title: "Nuovo")

      recent = described_class.recent(rule, limit: 1)

      expect(recent.size).to eq(1)
      expect(recent.first.title).to eq("Nuovo")
    end

    it "è vuoto quando la regola non è mai scattata" do
      expect(described_class.recent(rule)).to be_empty
    end
  end
end
