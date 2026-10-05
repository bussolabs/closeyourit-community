# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ops::CacheCanaryJob do
  describe "#perform" do
    # DoD CYRA-270: un'indisponibilità della cache condivisa deve lasciare una traccia nei log.
    it "logga un WARN quando il canarino trova la cache non disponibile" do
      allow(Ops::CacheCanary).to receive(:call)
        .and_return(Ops::CacheCanary::Result.new(available: false, error: "database is locked"))
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now

      expect(Rails.logger).to have_received(:warn).with(a_string_including("non raggiungibile"))
      expect(Rails.logger).to have_received(:warn).with(a_string_including("database is locked"))
    end

    it "non logga nulla quando la cache risponde (nessun rumore in salute)" do
      allow(Ops::CacheCanary).to receive(:call)
        .and_return(Ops::CacheCanary::Result.new(available: true, error: nil))
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now

      expect(Rails.logger).not_to have_received(:warn)
    end

    # CYRA-846 · DoD «se gli avvisi vengono sospesi, la cosa è visibile fuori dai log». Il WARN lo
    # legge solo chi sta già guardando i log: l'avviso arriva dove qualcuno lo vede davvero.
    it "alerts only the god's organization when the cache does not answer (CYRA-875)" do
      organization = create(:organization)
      create(:account, god: true).tap { |a| create(:membership, account: a, organization: organization) }
      allow(Ops::CacheCanary).to receive(:call)
        .and_return(Ops::CacheCanary::Result.new(available: false, error: "database is locked"))

      expect { described_class.perform_now }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "cache_unavailable", organization_id: organization.id,
                             subject_type: "Organizations::Organization", project_id: nil))
    end

    it "non avvisa nessuno quando la cache risponde" do
      create(:organization)
      allow(Ops::CacheCanary).to receive(:call)
        .and_return(Ops::CacheCanary::Result.new(available: true, error: nil))

      expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    # End-to-end con un null store (cache che non trattiene = giù): il giro deve lasciare la traccia
    # senza sollevare, così un guasto reale della cache non fa fallire e ritentare il canarino stesso.
    it "lascia la traccia e non solleva anche quando la cache è davvero giù" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::NullStore.new)
      allow(Rails.logger).to receive(:warn)

      expect { described_class.perform_now }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(a_string_including("Ops::CacheCanaryJob"))
    end
  end

  # Quando è nato (CYRA-270), :maintenance era un solo thread condiviso coi training AI fino a un'ora:
  # un job lungo avrebbe tenuto il canarino in coda per un'ora proprio durante un sovraccarico. Da
  # CYRA-714 quella corsia serve solo i controlli e reggerebbe anche lui, ma la scelta resta: il
  # canarino serve quando qualcosa va storto e :default è la corsia con più slot e meno giri periodici.
  it "gira sulla corsia real-time :default, non su una corsia a un thread" do
    expect(described_class.new.queue_name).to eq("default")
  end
end
