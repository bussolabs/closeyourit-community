# frozen_string_literal: true

require "rails_helper"

# CYRA-539 — chi accoda le misure di velocità e chi le esegue. Le due uscite silenziose del
# dispatcher sono la parte che conta: senza, la nostra configurazione mancante diventerebbe una riga
# fallita al giorno su ogni sito, e la storia dei controlli servirebbe a raccontare noi invece del
# sito.
#
# CYRA-546 — da qui in poi la chiave è dell'ORGANIZZAZIONE del sito: il dispatcher salta chi non l'ha
# collegata e tiene le quote separate, o la quota finita di una fermerebbe le misure di tutte.
RSpec.describe "Seo — job delle misure di velocità" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:) }

  def sito(**attributi)
    project.environments << environment unless project.environments.include?(environment)
    unless project.project_platforms.any?
      project.project_platforms.create!(platform: create(:platform, organization:, supports_analytics: true))
    end
    create(:seo_site, project:, environment:, **attributi)
  end

  # Un sito di un'ALTRA organizzazione, con la sua catena progetto/ambiente: serve a dire che le
  # quote e i collegamenti non si toccano fra organizzazioni.
  def sito_di(altra, **attributi)
    progetto = create(:project, organization: altra)
    ambiente = create(:environment, organization: altra)
    progetto.environments << ambiente
    progetto.project_platforms.create!(platform: create(:platform, organization: altra, supports_analytics: true))
    create(:seo_site, project: progetto, environment: ambiente, **attributi)
  end

  def collega(org) = create(:integration_credential, :pagespeed, organization: org)

  describe Seo::DispatchLabRunsJob do
    it "accoda due misure per ogni sito scaduto: telefono e computer" do
      collega(organization)
      scaduto = sito(next_lab_run_at: 1.hour.ago)

      expect { described_class.perform_now }
        .to have_enqueued_job(Seo::LabRunJob).with(scaduto.id, "mobile")
        .and have_enqueued_job(Seo::LabRunJob).with(scaduto.id, "desktop")
    end

    it "un sito non ancora scaduto o in pausa non viene toccato" do
      collega(organization)
      sito(next_lab_run_at: 5.hours.from_now)

      expect { described_class.perform_now }.not_to have_enqueued_job(Seo::LabRunJob)
    end

    # Una riga fallita per sito ogni ora riempirebbe la storia dei controlli con una configurazione
    # mancante. Un avviso nel log basta e si legge dove va letto — UNO per giro, non uno per sito.
    it "i siti di un'organizzazione che non ha collegato il servizio non vengono accodati, e lo dice una volta sola" do
      sito(next_lab_run_at: 1.hour.ago)
      sito_di(create(:organization), next_lab_run_at: 1.hour.ago)
      allow(Rails.logger).to receive(:warn)

      expect { described_class.perform_now }.not_to have_enqueued_job(Seo::LabRunJob)
      expect(Seo::LabRun.count).to eq(0)
      expect(Rails.logger).to have_received(:warn).once.with(/organizzazioni/)
    end

    # La quota è di chi ha collegato la chiave: quando è finita è finita per lei sola.
    it "a quota esaurita si ferma finché l'interruttore non scade" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      collega(organization)
      Rails.cache.write(Seo::PageSpeed::Constants.quota_exhausted_key(organization.id), true)
      sito(next_lab_run_at: 1.hour.ago)

      expect { described_class.perform_now }.not_to have_enqueued_job(Seo::LabRunJob)
    end

    it "la quota esaurita di un'organizzazione non ferma le misure delle altre" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      collega(organization)
      Rails.cache.write(Seo::PageSpeed::Constants.quota_exhausted_key(organization.id), true)
      fermo = sito(next_lab_run_at: 1.hour.ago)
      altra = create(:organization)
      collega(altra)
      libero = sito_di(altra, next_lab_run_at: 1.hour.ago)

      expect { described_class.perform_now }
        .to have_enqueued_job(Seo::LabRunJob).with(libero.id, "mobile")
        .and have_enqueued_job(Seo::LabRunJob).with(libero.id, "desktop")
      expect(Seo::LabRunJob).not_to have_been_enqueued.with(fermo.id, "mobile")
    end
  end

  describe Seo::LabRunJob do
    it "misura il sito con la strategia chiesta" do
      target = sito
      allow(Seo::MeasureLab).to receive(:call)

      described_class.perform_now(target.id, "desktop")

      expect(Seo::MeasureLab).to have_received(:call).with(site: target, strategy: "desktop")
    end

    # La corsia era UNA per tutta l'installazione: con le chiavi di ciascuno, una organizzazione con
    # molti siti terrebbe in fila le misure di tutte le altre, che pagano con un'altra chiave.
    it "serra la concorrenza per organizzazione, non per tutta l'installazione" do
      mio = sito
      altra = create(:organization)
      loro = sito_di(altra)

      expect(described_class.new(mio.id, "mobile").concurrency_key).to include(organization.id)
      expect(described_class.new(loro.id, "mobile").concurrency_key).to include(altra.id)
      # Le due strategie dello stesso sito restano invece nella stessa corsia: è la proprietà che
      # impedisce due misure sovrapposte sullo stesso sito.
      expect(described_class.new(mio.id, "desktop").concurrency_key)
        .to eq(described_class.new(mio.id, "mobile").concurrency_key)
    end

    # Un sito sparito non deve finire nella corsia comune di tutti: lì basterebbe una manciata di job
    # orfani per mettere in fila le misure di chiunque.
    it "un sito che non c'è più resta in una corsia sua" do
      orfano = SecureRandom.uuid

      expect(described_class.new(orfano, "mobile").concurrency_key).to include(orfano)
    end

    it "un sito sparito o in pausa non fa niente, senza rumore" do
      in_pausa = sito(enabled: false)
      allow(Seo::MeasureLab).to receive(:call)

      expect { described_class.perform_now(in_pausa.id, "mobile") }.not_to raise_error
      expect { described_class.perform_now(SecureRandom.uuid, "mobile") }.not_to raise_error
      expect(Seo::MeasureLab).not_to have_received(:call)
    end
  end

  describe Seo::PruneJob do
    it "pota le misure troppo vecchie e lascia stare le recenti" do
      target = sito
      vecchia = create(:seo_lab_run, :completed, site: target, started_at: 200.days.ago)
      recente = create(:seo_lab_run, :completed, site: target, started_at: 3.days.ago)

      described_class.perform_now

      expect(Seo::LabRun.exists?(vecchia.id)).to be(false)
      expect(Seo::LabRun.exists?(recente.id)).to be(true)
    end
  end
end
