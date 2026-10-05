# frozen_string_literal: true

require "rails_helper"

# CYRA-791 — un addestramento ucciso insieme al processo (deploy interrotto, worker terminato) non
# passa da nessun `rescue`: resta `pending`/`running` per sempre e la guardia anti-doppione di
# Datasets::Trainings::Start rifiuta OGNI avvio successivo su quel dataset. Qui si blinda il
# riconoscimento — chi è morto davvero e chi sta solo lavorando — e l'esito recuperabile.
RSpec.describe Datasets::Trainings::MarkStale, type: :service do
  let(:dataset) { create(:dataset) }
  let(:after) { Datasets::Constants::TRAINING_STALE_AFTER }

  def training(status:, heartbeat_at: nil, created_at: Time.current)
    create(:dataset_training, dataset: dataset, status: status, heartbeat_at: heartbeat_at,
                              created_at: created_at)
  end

  it "un addestramento in corso che non dà più segni di vita diventa un esito recuperabile" do
    stale = training(status: :running, heartbeat_at: (after + 1.minute).ago)

    result = described_class.call

    expect(result).to be_ok
    expect(result.value).to eq(1)
    expect(stale.reload).to be_status_failed
    expect(stale.error_code).to eq("R500-DATASET-001")
    expect(stale.error_message).to eq(I18n.t("datasets.errors.interrupted"))
  end

  # Il rischio opposto, e più grave: dichiarare morto un addestramento LENTO ma vivo significherebbe
  # farne partire un secondo mentre il primo sta ancora pagando chiamate AI.
  it "un addestramento che ha battuto da poco resta in corso" do
    alive = training(status: :running, heartbeat_at: 5.minutes.ago, created_at: (after + 1.hour).ago)

    expect(described_class.call.value).to eq(0)
    expect(alive.reload).to be_status_running
  end

  # Il lavoro può morire anche PRIMA di partire: accodato e mai preso in carico, resta `pending` senza
  # aver mai battuto. Lì il segno di vita è la creazione.
  it "un addestramento mai partito oltre la soglia diventa recuperabile, uno appena creato no" do
    orphan = training(status: :pending, created_at: (after + 1.minute).ago)
    fresh = training(status: :pending, created_at: 1.minute.ago)

    expect(described_class.call.value).to eq(1)
    expect(orphan.reload).to be_status_failed
    expect(fresh.reload).to be_status_pending
  end

  it "non tocca gli esiti già scritti: un secondo giro non trova più niente da chiudere" do
    done = training(status: :done, created_at: 1.year.ago)
    failed = training(status: :failed, created_at: 1.year.ago)
    training(status: :running, heartbeat_at: (after + 1.minute).ago)

    expect(described_class.call.value).to eq(1)
    expect(described_class.call.value).to eq(0)
    expect(done.reload).to be_status_done
    expect(failed.reload).to be_status_failed
  end

  it "con un insieme di dati indicato lascia stare gli addestramenti degli altri" do
    mine = training(status: :running, heartbeat_at: (after + 1.minute).ago)
    other = create(:dataset_training, status: :running, heartbeat_at: (after + 1.minute).ago)

    expect(described_class.call(dataset: dataset).value).to eq(1)
    expect(mine.reload).to be_status_failed
    expect(other.reload).to be_status_running
  end

  # L'esito passa dall'imbuto unico del modello (finish_err!), quindi chi segue il dataset viene
  # avvisato come per qualunque altro fallimento: un addestramento morto in silenzio è il problema.
  it "avvisa dell'esito come per ogni altro fallimento" do
    stale = training(status: :running, heartbeat_at: (after + 1.minute).ago)

    expect { described_class.call }
      .to have_enqueued_job(Alerting::EvaluateJob).with(
        hash_including(event_type: "dataset_training_failed", subject_type: "Datasets::Training",
                       subject_id: stale.id)
      )
  end
end
