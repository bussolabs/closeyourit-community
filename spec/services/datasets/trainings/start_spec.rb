# frozen_string_literal: true

require "rails_helper"

# CYRA-647 — la regola di avvio di un addestramento (righe minime, mai due sullo stesso insieme di
# dati) è UNA sola: la usano sia la pagina sia il canale da terminale. Qui si blinda
# il service; i due canali sono coperti dai rispettivi request spec.
RSpec.describe Datasets::Trainings::Start, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:actor) { create(:account) }
  let(:dataset) { create(:dataset, project:) }

  let!(:foto) { create(:dataset_column, :photo, dataset:, code: "foto") }
  let!(:esito) { create(:dataset_column, :target, dataset:, code: "esito", kind: :category, options: %w[ok ko]) }

  def add_sample_rows(count)
    count.times { create(:dataset_row, dataset:, purpose: :sample, cell_values: { "esito" => "ok" }) }
  end

  it "con abbastanza righe crea l'addestramento in attesa e accoda il lavoro" do
    add_sample_rows(Datasets::Constants::MIN_SAMPLE_ROWS)

    result = nil
    expect { result = described_class.call(dataset:, actor:) }.to have_enqueued_job(Datasets::TrainJob)

    expect(result).to be_ok
    expect(result.value).to be_status_pending
    expect(result.value.created_by).to eq(actor)
  end

  it "righe insufficienti → R422-DATASET-004 e nessun addestramento" do
    add_sample_rows(Datasets::Constants::MIN_SAMPLE_ROWS - 1)

    result = nil
    expect { result = described_class.call(dataset:, actor:) }.not_to change(Datasets::Training, :count)

    expect(result.error.code).to eq("R422-DATASET-004")
    expect(result.error.message).to eq(I18n.t("datasets.errors.not_enough"))
  end

  it "un addestramento in corso → R409-DATASET-001, niente doppio costo" do
    create(:dataset_training, dataset:, status: :running)
    add_sample_rows(Datasets::Constants::MIN_SAMPLE_ROWS)

    result = nil
    expect { result = described_class.call(dataset:, actor:) }.not_to have_enqueued_job(Datasets::TrainJob)

    expect(Datasets::Training.count).to eq(1)
    expect(result.error.code).to eq("R409-DATASET-001")
    expect(result.error.status).to eq(:conflict)
  end

  # CYRA-791 — l'addestramento ucciso col processo resta "in corso" e blocca ogni avvio successivo.
  # Il recupero deve valere sulla RICHIESTA, non solo nel giro periodico: quel giro vive nello stesso
  # motore dei lavori che è appena morto, quindi proprio nello scenario del guasto non parte.
  describe "recupero di un addestramento interrotto (CYRA-791)" do
    before { add_sample_rows(Datasets::Constants::MIN_SAMPLE_ROWS) }

    it "un addestramento senza segni di vita oltre la soglia non blocca il nuovo avvio" do
      interrotto = create(:dataset_training, dataset:, status: :running,
                                             heartbeat_at: (Datasets::Constants::TRAINING_STALE_AFTER + 1.minute).ago)

      result = nil
      expect { result = described_class.call(dataset:, actor:) }.to have_enqueued_job(Datasets::TrainJob)

      expect(result).to be_ok
      expect(result.value).to be_status_pending
      expect(interrotto.reload).to be_status_failed
      expect(interrotto.error_code).to eq("R500-DATASET-001")
    end

    it "un addestramento che sta ancora lavorando resta protetto: nessun doppio costo" do
      vivo = create(:dataset_training, dataset:, status: :running, heartbeat_at: 1.minute.ago,
                                       created_at: (Datasets::Constants::TRAINING_STALE_AFTER + 1.hour).ago)

      result = nil
      expect { result = described_class.call(dataset:, actor:) }.not_to have_enqueued_job(Datasets::TrainJob)

      expect(result.error.code).to eq("R409-DATASET-001")
      expect(vivo.reload).to be_status_running
      expect(Datasets::Training.count).to eq(1)
    end
  end

  # CYRA-246: se l'accodamento fallisce, l'addestramento appena creato NON deve restare in attesa,
  # altrimenti la guardia "già in corso" bloccherebbe ogni avvio futuro per sempre.
  it "accodamento fallito → nessun addestramento orfano" do
    add_sample_rows(Datasets::Constants::MIN_SAMPLE_ROWS)
    allow(Datasets::TrainJob).to receive(:perform_later).and_raise(StandardError, "coda non disponibile")

    expect { described_class.call(dataset:, actor:) }.to raise_error(StandardError, "coda non disponibile")

    expect(Datasets::Training.where(status: %i[pending running])).to be_empty
  end
end
