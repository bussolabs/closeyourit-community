# frozen_string_literal: true

require "rails_helper"

# Rilevamento spike/surge (CYRA-38): un Errors::Group GIÀ unresolved a basso volume che esplode
# (es. dopo un deploy) non è né nuovo né una regressione → notify_alerts lo ignorerebbe. Qui la
# detection confronta il bucket corrente col rate di baseline (Errors::Group.buckets_for) ed emette
# EvaluateJob(event_type: "error_spike") oltre una soglia minima assoluta + un fattore relativo,
# con un throttle proprio per non riemettere ad ogni campione.
RSpec.describe Errors::Ingest::Record, "spike detection", type: :service do
  include ActiveJob::TestHelper

  # Il throttle di detection usa la cache atomica (unless_exist), no-op sotto :null_store di test →
  # come evaluate_spec per i canali, sostituiamo una cache reale, fresca per ogni esempio.
  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  let(:project) { create(:project) }

  # Payload deterministico → stesso fingerprint (indipendente da event_id/timestamp) → stesso gruppo.
  def spike_payload(occurred: Time.current)
    {
      "event_id" => SecureRandom.hex(16),
      "level" => "error",
      "environment" => "production",
      "timestamp" => occurred.to_f,
      "exception" => { "values" => [ {
        "type" => "RuntimeError", "value" => "boom",
        "stacktrace" => { "frames" => [ { "module" => "App", "function" => "call", "in_app" => true } ] }
      } ] }
    }
  end

  # Fingerprint stabile del payload sopra (non dipende da event_id né timestamp).
  let(:fingerprint) { Errors::Fingerprint.call(payload: spike_payload) }

  # Gruppo pre-esistente con lo stesso fingerprint del payload → record vi aggiunge l'occorrenza.
  def existing_group(status: :unresolved)
    create(:error_group, project:, fingerprint:, status:, events_count: 5)
  end

  # N occorrenze reali del gruppo (Errors::Event) a un dato istante → alimentano buckets_for.
  def seed_events(group, count, at)
    create_list(:error_event, count, group:, project:, occurred_at: at)
  end

  # L'occorrenza cade a now-10s: dentro l'ultimo bucket [now-1min, now) E prima di `now`, quindi
  # inclusa dal range esclusivo `since...now` di buckets_for → current = seed + 1 deterministico.
  def record(occurred: Time.current - 10.seconds) = described_class.call(project:, payload: spike_payload(occurred:))

  # L'ultimo bucket della finestra "30m" è [now-1min, now): now-20s ci cade dentro.
  let(:in_current_bucket) { Time.current - 20.seconds }
  let(:min_count) { Errors::Constants::SPIKE_MIN_COUNT }

  describe "Scenario 1 — un errore unresolved dormiente che esplode" do
    it "accoda EvaluateJob error_spike col contratto atteso" do
      travel_to Time.utc(2026, 6, 1, 12) do
        group = existing_group
        seed_events(group, 40, in_current_bucket) # ~esplosione post-deploy, baseline a zero

        expect { record }
          .to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "error_spike", subject_type: "Errors::Group",
                               subject_id: group.id, project_id: project.id,
                               environment: "production", level: Errors::Group.levels["error"]))
      end
    end
  end

  describe "confine: soglia minima assoluta (baseline a zero)" do
    it "current == MIN_COUNT-1 → nessun alert" do
      travel_to Time.utc(2026, 6, 1, 12) do
        group = existing_group
        seed_events(group, min_count - 2, in_current_bucket) # + l'occorrenza di record = MIN-1
        expect { record }.not_to have_enqueued_job(Alerting::EvaluateJob)
      end
    end

    it "current == MIN_COUNT → alert error_spike" do
      travel_to Time.utc(2026, 6, 1, 12) do
        group = existing_group
        seed_events(group, min_count - 1, in_current_bucket) # + l'occorrenza di record = MIN
        expect { record }
          .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "error_spike"))
      end
    end
  end

  describe "confine: fattore relativo (spike vs baseline)" do
    it "current oltre la soglia assoluta ma sotto FACTOR× la baseline → nessun alert" do
      travel_to Time.utc(2026, 6, 1, 12) do
        group = existing_group
        seed_events(group, 300, Time.current - 10.minutes) # baseline alta nei bucket precedenti
        seed_events(group, min_count + 5, in_current_bucket) # current sopra MIN, ma < FACTOR×avg
        expect { record }.not_to have_enqueued_job(Alerting::EvaluateJob)
      end
    end

    it "current oltre la soglia assoluta E oltre FACTOR× la baseline → alert error_spike" do
      travel_to Time.utc(2026, 6, 1, 12) do
        group = existing_group
        seed_events(group, 29, Time.current - 10.minutes) # baseline bassa (avg ~1/bucket)
        seed_events(group, 60, in_current_bucket) # current 61 ≫ FACTOR×avg
        expect { record }
          .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "error_spike"))
      end
    end
  end

  describe "non-transizioni che NON sono spike" do
    it "gruppo unresolved con traffico modesto → nessun alert" do
      travel_to Time.utc(2026, 6, 1, 12) do
        group = existing_group
        seed_events(group, 3, in_current_bucket)
        expect { record }.not_to have_enqueued_job(Alerting::EvaluateJob)
      end
    end

    it "gruppo ignored che esplode → nessun alert (muto per scelta operatore)" do
      travel_to Time.utc(2026, 6, 1, 12) do
        group = existing_group(status: :ignored)
        seed_events(group, 40, in_current_bucket)
        expect { record }.not_to have_enqueued_job(Alerting::EvaluateJob)
      end
    end

    it "primo evento (gruppo nuovo) → mai error_spike" do
      travel_to Time.utc(2026, 6, 1, 12) do
        expect { record }
          .not_to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "error_spike"))
      end
    end
  end

  describe "throttle proprio: non ripetere l'alert ad ogni campione" do
    it "burst ripetuti nella stessa finestra → un solo error_spike per gruppo" do
      travel_to Time.utc(2026, 6, 1, 12) do
        group = existing_group
        seed_events(group, 40, in_current_bucket)

        expect { record }
          .to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "error_spike")).exactly(:once)
        expect { record }.not_to have_enqueued_job(Alerting::EvaluateJob)
      end
    end

    it "spike confermato poi altro burst entro il cooldown → nessun secondo alert" do
      group = nil
      start = Time.utc(2026, 6, 1, 12)
      travel_to(start) do
        group = existing_group
        seed_events(group, 40, in_current_bucket)
        record # → error_spike (scrive il cooldown)
      end
      travel_to(start + Errors::Constants::SPIKE_PROBE_INTERVAL + 1.second) do
        seed_events(group, 40, Time.current - 20.seconds) # ancora spike, ma entro il cooldown
        expect { record }.not_to have_enqueued_job(Alerting::EvaluateJob)
      end
    end

    # Regressione: un'occorrenza normale NON deve consumare il budget di detection oltre il probe
    # breve. Col vecchio throttle unico (acquisito prima di spiking?), un burst iniziato subito dopo
    # un campione innocuo restava cieco per l'intero cooldown.
    it "un'occorrenza normale non ceca la detection di un burst successivo oltre il probe" do
      group = nil
      start = Time.utc(2026, 6, 1, 12)
      travel_to(start) do
        group = existing_group
        record # traffico basso → nessuno spike, ma il vecchio design avrebbe preso il lock lungo
      end
      travel_to(start + Errors::Constants::SPIKE_PROBE_INTERVAL + 1.second) do
        seed_events(group, 40, Time.current - 20.seconds) # esplosione dopo la scadenza del probe
        expect { record }
          .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "error_spike"))
      end
    end
  end
end
