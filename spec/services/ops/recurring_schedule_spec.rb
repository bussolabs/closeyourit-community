# frozen_string_literal: true

require "rails_helper"

# CYRA-752 — su staging i giri ricorrenti non partivano mai e nessuno poteva accorgersene.
#
# I due segnali sono INDIPENDENTI, come per il motore dei job (CYRA-299): lo Scheduler può battere
# l'heartbeat e non accodare niente. Guardarne uno solo lascia scoperta metà dei guasti.
RSpec.describe Ops::RecurringSchedule, type: :service do
  # Nei test non gira uno Scheduler vero: registriamo a mano la riga in solid_queue_processes, come
  # fa spec/services/ops/worker_liveness_spec.rb per il Worker.
  def register_process(last_heartbeat_at:, kind: "Scheduler", name: "scheduler-1")
    SolidQueue::Process.create!(kind:, name:, pid: 1, last_heartbeat_at:)
  end

  # Una riga in solid_queue_recurring_executions = un giro davvero accodato dallo Scheduler.
  def record_run(run_at:, task_key: "cache_canary")
    job = SolidQueue::Job.create!(queue_name: "default", class_name: "Ops::CacheCanaryJob",
                                  active_job_id: SecureRandom.uuid)
    SolidQueue::RecurringExecution.create!(job:, task_key:, run_at:)
  end

  describe ".configured?" do
    # recurring.yml declares no task for test: there is nothing to watch, which is not the same as broken.
    it "false negli ambienti dove non è dichiarato nessun giro ricorrente" do
      expect(described_class.configured?).to be(false)
    end
  end

  describe ".last_heartbeat_at" do
    it "ritorna il battito dello Scheduler quando è recente" do
      travel_to(Time.utc(2026, 9, 2, 12)) do
        register_process(last_heartbeat_at: 30.seconds.ago)
        expect(described_class.last_heartbeat_at).to be_within(1.second).of(30.seconds.ago)
      end
    end

    it "nil quando il battito è più vecchio della soglia (Scheduler fermo)" do
      register_process(last_heartbeat_at: described_class::HEARTBEAT_TIMEOUT.ago - 1.minute)
      expect(described_class.last_heartbeat_at).to be_nil
    end

    it "nil se battono solo Worker e Dispatcher: chi accoda i giri è lo Scheduler" do
      register_process(last_heartbeat_at: Time.current, kind: "Worker", name: "w")
      register_process(last_heartbeat_at: Time.current, kind: "Dispatcher", name: "d")

      expect(described_class.last_heartbeat_at).to be_nil
    end
  end

  describe ".last_run_at" do
    it "ritorna l'accodamento ricorrente più recente" do
      travel_to(Time.utc(2026, 9, 2, 12)) do
        record_run(run_at: 5.minutes.ago, task_key: "evaluate_crons")
        record_run(run_at: 1.minute.ago, task_key: "cache_canary")

        expect(described_class.last_run_at).to be_within(1.second).of(1.minute.ago)
      end
    end

    it "nil quando lo Scheduler non ha ancora accodato niente" do
      expect(described_class.last_run_at).to be_nil
    end
  end

  describe ".last_run_age_seconds" do
    it "dice da quanti secondi il motore non accoda" do
      travel_to(Time.utc(2026, 9, 2, 12)) do
        record_run(run_at: 90.seconds.ago)

        expect(described_class.last_run_age_seconds).to be_within(1).of(90)
      end
    end

    it "nil quando non è mai stato accodato niente" do
      expect(described_class.last_run_age_seconds).to be_nil
    end

    # Chi legge da fuori confronta questa età con quanto è durata la propria attesa: un valore
    # negativo (orologi disallineati fra web e database) la farebbe passare per freschissima.
    it "non scende sotto zero" do
      travel_to(Time.utc(2026, 9, 2, 12)) do
        record_run(run_at: 30.seconds.from_now)

        expect(described_class.last_run_age_seconds).to eq(0)
      end
    end
  end

  describe ".status" do
    context "quando l'ambiente non dichiara giri ricorrenti" do
      before { allow(described_class).to receive(:configured?).and_return(false) }

      # Spento di proposito ≠ guasto, come `/up/embedding` con gli embedding disattivati.
      it "è :disabled anche senza Scheduler e senza accodamenti" do
        expect(described_class.status).to eq(:disabled)
      end
    end

    context "quando l'ambiente dichiara giri ricorrenti" do
      before { allow(described_class).to receive(:configured?).and_return(true) }

      it "è :down senza uno Scheduler vivo: nessuno accoderà i giri" do
        travel_to(Time.utc(2026, 9, 2, 12)) do
          record_run(run_at: 1.minute.ago)

          expect(described_class.status).to eq(:down)
        end
      end

      it "è :stale con lo Scheduler vivo che però non accoda da troppo" do
        travel_to(Time.utc(2026, 9, 2, 12)) do
          register_process(last_heartbeat_at: 30.seconds.ago)
          record_run(run_at: described_class::STALE_THRESHOLD.ago - 1.minute)

          expect(described_class.status).to eq(:stale)
        end
      end

      it "è :stale con lo Scheduler vivo e nessun accodamento mai registrato" do
        register_process(last_heartbeat_at: Time.current)

        expect(described_class.status).to eq(:stale)
      end

      it "è :up quando lo Scheduler batte e ha accodato di recente" do
        travel_to(Time.utc(2026, 9, 2, 12)) do
          register_process(last_heartbeat_at: 30.seconds.ago)
          record_run(run_at: 1.minute.ago)

          expect(described_class.status).to eq(:up)
        end
      end
    end
  end

  describe "::STALE_THRESHOLD" do
    # I giri più fitti di config/recurring.yml scattano ogni minuto. La soglia deve stare larga
    # rispetto a quella cadenza: la potatura oraria dei job finiti cancella a cascata anche le righe
    # degli accodamenti (chiave esterna con on_delete: :cascade), quindi per il minuto successivo al
    # prune l'ultimo accodamento visibile può essere nessuno.
    it "è abbastanza larga da assorbire la potatura oraria dei job finiti" do
      expect(described_class::STALE_THRESHOLD).to be >= 5.minutes
    end
  end
end
