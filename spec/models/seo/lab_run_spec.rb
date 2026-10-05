# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::LabRun do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:) }
  let(:site) do
    project.environments << environment
    project.project_platforms.create!(platform: create(:platform, organization:, supports_analytics: true))
    create(:seo_site, project:, environment:)
  end

  # CYRA-539 — un giro fallito non sostituisce mai i numeri buoni: la scheda mostra quelli di prima
  # dicendo che sono vecchi, invece di non mostrare niente.
  describe ".last_completed" do
    it "prende l'ultimo giro RIUSCITO di quella strategia, non l'ultimo in assoluto" do
      vecchio = create(:seo_lab_run, :completed, site:, strategy: :mobile, started_at: 2.days.ago)
      create(:seo_lab_run, :failed, site:, strategy: :mobile, started_at: 1.hour.ago)
      create(:seo_lab_run, :completed, :desktop, site:, started_at: 1.hour.ago)

      expect(described_class.last_completed("mobile")).to eq(vecchio)
    end
  end

  describe "le misure raccolte" do
    subject(:run) { create(:seo_lab_run, :completed, :with_field, site:) }

    it "espone laboratorio, campo e punteggi con le loro sigle" do
      expect(run.lab_metrics).to include("lcp" => 2_842, "cls" => 0.0421, "tbt" => 310)
      expect(run.field_metrics).to include("lcp" => 3_120, "inp" => 184)
      expect(run.scores).to include("performance" => 72, "seo" => 88)
    end

    it "dice quanto è durata la misura" do
      expect(run.duration_seconds).to be >= 0
      expect(create(:seo_lab_run, site:).duration_seconds).to be_nil
    end

    # Una misura che Google non ha calcolato resta nil lungo tutta la catena: se diventasse zero, la
    # pagina la dipingerebbe di verde e direbbe il contrario di quello che sa.
    it "un giro senza numeri espone nil, non zeri" do
      vuoto = create(:seo_lab_run, site:)

      expect(vuoto.lab_metrics.values).to all(be_nil)
      expect(vuoto.field_metrics.values).to all(be_nil)
      expect(vuoto.scores.values).to all(be_nil)
    end
  end

  # Se Google non ha abbastanza dati sul sito, la pagina lo scrive invece di mostrare una fila di
  # trattini che sembra un guasto nostro.
  describe "#field?" do
    it "è falso quando Google non ha dati di campo su questo sito" do
      expect(create(:seo_lab_run, :completed, site:)).not_to be_field
      expect(create(:seo_lab_run, :completed, :with_field, site:)).to be_field
    end
  end
end
