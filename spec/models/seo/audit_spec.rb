# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::Audit, type: :model do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org) }

  before do
    project.environments << environment
    project.project_platforms.create!(platform: create(:platform, organization: org, supports_analytics: true))
  end

  # CYRA-818 — l'elenco dei siti abbinava la data dell'ultimo giro al numero di pagine di un giro
  # precedente. Chi legge la riga vede due fatti che sembrano dello stesso controllo: se non lo sono,
  # il riepilogo della copertura non è verificabile contro la cronologia del dettaglio.
  describe ".latest_per_site" do
    it "sceglie il giro più recente di ciascun sito" do
      primo = create(:seo_site, project:, environment:)
      audit_vecchio = create(:seo_audit, :completed, site: primo, started_at: 3.days.ago, pages_count: 23)
      audit_nuovo = create(:seo_audit, :completed, site: primo, started_at: 1.hour.ago, pages_count: 79)

      ultimi = described_class.latest_per_site([ primo.id ])

      expect(ultimi.map(&:id)).to contain_exactly(audit_nuovo.id)
      expect(ultimi.first.pages_count).to eq(79)
      expect(ultimi.map(&:id)).not_to include(audit_vecchio.id)
    end

    it "torna una riga sola per sito, non tutta la cronologia" do
      sito = create(:seo_site, project:, environment:)
      5.times { |i| create(:seo_audit, :completed, site: sito, started_at: i.days.ago) }

      expect(described_class.latest_per_site([ sito.id ]).size).to eq(1)
    end

    it "tiene separati due siti, ciascuno col proprio ultimo giro" do
      primo = create(:seo_site, project:, environment:)
      altro_env = create(:environment, organization: org)
      project.environments << altro_env
      secondo = create(:seo_site, project:, environment: altro_env, base_url: "https://altro.test")
      create(:seo_audit, :completed, site: primo, started_at: 2.days.ago, pages_count: 23)
      create(:seo_audit, :completed, site: primo, started_at: 1.hour.ago, pages_count: 79)
      create(:seo_audit, :completed, site: secondo, started_at: 2.hours.ago, pages_count: 64)

      ultimi = described_class.latest_per_site([ primo.id, secondo.id ]).index_by(&:site_id)

      expect(ultimi[primo.id].pages_count).to eq(79)
      expect(ultimi[secondo.id].pages_count).to eq(64)
    end

    it "a parità di istante sceglie sempre lo stesso giro" do
      sito = create(:seo_site, project:, environment:)
      istante = 1.hour.ago
      3.times { |i| create(:seo_audit, :completed, site: sito, started_at: istante, pages_count: 10 + i) }

      scelti = 3.times.map { described_class.latest_per_site([ sito.id ]).first.id }

      expect(scelti.uniq.size).to eq(1)
      expect(scelti.first).to eq(sito.audits.recent.first.id)
    end

    it "salta il giro ancora in corso: i suoi numeri non sono ancora numeri" do
      sito = create(:seo_site, project:, environment:)
      concluso = create(:seo_audit, :completed, site: sito, started_at: 2.hours.ago, pages_count: 79)
      create(:seo_audit, site: sito, status: :running, started_at: 1.minute.ago, pages_count: 0)

      expect(described_class.latest_per_site([ sito.id ]).map(&:id)).to eq([ concluso.id ])
    end

    it "un sito senza giri non compare" do
      sito = create(:seo_site, project:, environment:)

      expect(described_class.latest_per_site([ sito.id ])).to be_empty
    end

    it "senza siti non interroga niente" do
      expect(described_class.latest_per_site([])).to be_empty
    end
  end

  # La cronologia del dettaglio e l'elenco devono nominare lo stesso giro: due ordini diversi a
  # parità di istante farebbero leggere due numeri diversi per lo stesso controllo.
  describe ".recent" do
    it "a parità di istante non cambia ordine da una lettura all'altra" do
      sito = create(:seo_site, project:, environment:)
      istante = 1.hour.ago
      3.times { create(:seo_audit, :completed, site: sito, started_at: istante) }

      letture = 3.times.map { sito.audits.recent.map(&:id) }

      expect(letture.uniq.size).to eq(1)
    end
  end
end
