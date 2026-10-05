# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::Training, type: :model do
  include ActiveJob::TestHelper

  describe "enum status" do
    it "definisce gli stati con prefisso" do
      expect(described_class.statuses).to eq("pending" => 0, "running" => 1, "done" => 2, "failed" => 3)
    end
  end

  describe "#finish_ok!" do
    it "salva prompt, config e metriche marcando done" do
      training = create(:dataset_training, status: :running)
      training.finish_ok!(system_prompt: "Sei un classificatore.", config: { "iterations" => 2 },
                          metrics: { "accuracy" => 0.8 })

      expect(training.reload).to be_status_done
      expect(training.system_prompt).to eq("Sei un classificatore.")
      expect(training.config).to eq("iterations" => 2)
      expect(training.metrics).to eq("accuracy" => 0.8)
    end

    # CYRA-147: all'esito positivo scatta l'avviso rule-based dataset_training_completed.
    it "accoda l'avviso dataset_training_completed, project-scoped via il dataset" do
      training = create(:dataset_training, status: :running)

      expect { training.finish_ok!(system_prompt: "x") }
        .to have_enqueued_job(Alerting::EvaluateJob).with(
          hash_including(event_type: "dataset_training_completed", subject_type: "Datasets::Training",
                         subject_id: training.id, project_id: training.dataset.project_id)
        )
    end
  end

  describe "#finish_err!" do
    it "salva codice e messaggio marcando failed" do
      training = create(:dataset_training, status: :running)
      training.finish_err!(code: "R502-DATASET-001", message: "Gateway giù")

      expect(training.reload).to be_status_failed
      expect(training.error_code).to eq("R502-DATASET-001")
      expect(training.error_message).to eq("Gateway giù")
    end

    # CYRA-147: all'esito negativo scatta l'avviso rule-based dataset_training_failed.
    it "accoda l'avviso dataset_training_failed, project-scoped via il dataset" do
      training = create(:dataset_training, status: :running)

      expect { training.finish_err!(code: "R502-DATASET-001", message: "Gateway giù") }
        .to have_enqueued_job(Alerting::EvaluateJob).with(
          hash_including(event_type: "dataset_training_failed", subject_type: "Datasets::Training",
                         subject_id: training.id, project_id: training.dataset.project_id)
        )
    end
  end

  # CYRA-791 — il segno di vita dell'esecuzione in corso e la sua lettura.
  describe "segno di vita (CYRA-791)" do
    it "#beat! registra il momento del battito" do
      training = create(:dataset_training, status: :running)

      freeze_time do
        training.beat!
        expect(training.reload.heartbeat_at).to eq(Time.current)
      end
    end

    it "senza battiti il segno di vita è la creazione" do
      training = create(:dataset_training, status: :pending, created_at: 2.hours.ago)

      expect(training.last_signal_at).to eq(training.created_at)
    end

    it ".stale_at prende solo pending e running oltre la soglia" do
      running_fermo = create(:dataset_training, status: :running, heartbeat_at: 3.hours.ago)
      pending_vecchio = create(:dataset_training, status: :pending, created_at: 3.hours.ago)
      create(:dataset_training, status: :running, heartbeat_at: 1.minute.ago)
      create(:dataset_training, status: :failed, created_at: 3.hours.ago)

      expect(described_class.stale_at(Time.current, after: 2.hours))
        .to contain_exactly(running_fermo, pending_vecchio)
    end
  end

  # CYRA-791 — un esito è definitivo. Se il giro di recupero ha già dichiarato interrotto un
  # addestramento e il processo che lo eseguiva risorge, la sua conclusione NON deve riscrivere
  # l'esito già mostrato (né far partire un secondo avviso per lo stesso addestramento).
  describe "gli esiti sono terminali" do
    it "finish_ok! non riporta a done un addestramento già chiuso" do
      training = create(:dataset_training, status: :failed, error_code: "R500-DATASET-001")

      expect { training.finish_ok!(system_prompt: "tardi") }.not_to have_enqueued_job(Alerting::EvaluateJob)
      expect(training.reload).to be_status_failed
      expect(training.system_prompt).to be_nil
    end

    # Il caso vero: chi arriva tardi ha in mano una copia di ORE prima, che dice ancora `running`.
    # Se la domanda «è già chiuso?» si facesse su quella, la guardia non scatterebbe mai.
    it "un esito arrivato tardi non riscrive quello registrato da un altro processo" do
      training = create(:dataset_training, status: :running)
      stale_view = described_class.find(training.id)
      described_class.find(training.id).finish_err!(code: "R500-DATASET-001", message: "interrotto")

      expect(stale_view.finish_ok!(system_prompt: "tardi")).to be(false)
      expect(training.reload).to be_status_failed
      expect(training.error_code).to eq("R500-DATASET-001")
    end

    it "finish_err! non riscrive il motivo di un addestramento già chiuso" do
      training = create(:dataset_training, status: :done, system_prompt: "buono")

      expect { training.finish_err!(code: "R500-SYSTEM-001", message: "tardi") }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
      expect(training.reload).to be_status_done
      expect(training.error_code).to be_nil
    end
  end

  describe "dependent: :nullify sulle predizioni" do
    it "scollega le predizioni senza distruggerle quando il training viene cancellato" do
      training = create(:dataset_training)
      prediction = create(:dataset_prediction, dataset_record: training.dataset, training: training)

      training.destroy

      expect(prediction.reload.training_id).to be_nil
    end
  end
end
