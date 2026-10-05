# frozen_string_literal: true

require "rails_helper"

# CYRA-700 — il canale d'ingresso della telemetria d'uso esiste (CYSK-29) ma l'applicazione non gli
# mandava niente: 359 funzionalità e zero eventi. Questo è il lato che parla, e parla della SUA
# esecuzione — la stessa forma che usa un SDK esterno: `Controller#action`, mai l'URL.
RSpec.describe Usage::SelfRecorder, type: :service do
  let(:project) { create(:project) }

  before { described_class.reset! }
  after { described_class.reset! }

  describe "spento" do
    it "senza progetto configurato non tiene niente in memoria" do
      described_class.record("Member::TicketsController#index")

      expect(described_class.buffered).to be_empty
    end

    it "senza progetto configurato non accoda nessun flush" do
      described_class.record("Member::TicketsController#index")

      expect { described_class.flush_if_due!(now: 1.hour.from_now) }
        .not_to have_enqueued_job(Usage::IngestJob)
    end
  end

  describe "acceso" do
    before { allow(described_class).to receive(:project_id).and_return(project.id) }

    it "tiene il simbolo con l'ultima volta che è stato visto" do
      described_class.record("Member::TicketsController#index")
      described_class.record("Member::TicketsController#index")

      expect(described_class.buffered.keys).to eq([ [ "route", "Member::TicketsController#index" ] ])
      expect(described_class.buffered.fetch([ "route", "Member::TicketsController#index" ])[:count]).to eq(2)
    end

    it "scarta un simbolo fuori contratto invece di sporcare la tabella" do
      described_class.record("Member::TicketsController#index?id=42&token=segreto")

      expect(described_class.buffered).to be_empty
    end

    it "non accoda niente prima che la finestra sia scaduta" do
      described_class.record("Member::TicketsController#index")

      expect { described_class.flush_if_due! }.not_to have_enqueued_job(Usage::IngestJob)
    end

    it "a finestra scaduta accoda UN flush con tutti i simboli e svuota" do
      described_class.record("Member::TicketsController#index")
      described_class.record("Member::ProjectsController#show")

      expect { described_class.flush_if_due!(now: Time.current + described_class::WINDOW + 1.second) }
        .to have_enqueued_job(Usage::IngestJob).once

      expect(described_class.buffered).to be_empty
    end

    it "a buffer vuoto non accoda un flush vuoto" do
      expect { described_class.flush_if_due!(now: Time.current + described_class::WINDOW + 1.second) }
        .not_to have_enqueued_job(Usage::IngestJob)
    end

    it "tiene separati due kind dello stesso simbolo invece di sommarli" do
      described_class.record("tickets", kind: "feature_view")
      described_class.record("tickets", kind: "custom")

      expect(described_class.buffered.keys)
        .to match_array([ [ "feature_view", "tickets" ], [ "custom", "tickets" ] ])
    end

    it "scarta un kind fuori contratto invece di sporcare la tabella" do
      described_class.record("tickets", kind: "pagina")

      expect(described_class.buffered).to be_empty
    end

    it "il flush porta il kind con cui il simbolo è stato registrato" do
      described_class.record("tickets", kind: "feature_view")

      described_class.flush_if_due!(now: Time.current + described_class::WINDOW + 1.second)
      argomenti = ActiveJob::Base.queue_adapter.enqueued_jobs.last.fetch("arguments").first
      Usage::IngestJob.new.perform(**argomenti.except("_aj_ruby2_keywords").symbolize_keys)

      expect(Usage::Symbol.sole).to have_attributes(kind: "feature_view", symbol: "tickets")
    end

    it "il flush arriva in tabella come simbolo di rotta, senza dati personali" do
      described_class.record("Member::TicketsController#index")

      described_class.flush_if_due!(now: Time.current + described_class::WINDOW + 1.second)
      argomenti = ActiveJob::Base.queue_adapter.enqueued_jobs.last.fetch("arguments").first
      Usage::IngestJob.new.perform(**argomenti.except("_aj_ruby2_keywords").symbolize_keys)

      symbol = Usage::Symbol.sole
      expect(symbol).to have_attributes(project_id: project.id, kind: "route",
                                        symbol: "Member::TicketsController#index")
      expect(symbol.attributes.values.join(" ")).not_to include("@")
    end
  end
end
