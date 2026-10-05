# frozen_string_literal: true

require "rails_helper"

# CYRA-647 — la regola di avvio di una previsione (serve un addestramento riuscito, la riga in
# ingresso si scrive con lo stesso service delle altre) è UNA sola: la usano sia la pagina sia il
# canale da terminale.
RSpec.describe Datasets::Predictions::Start, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:actor) { create(:account) }
  let(:dataset) { create(:dataset, project:) }

  let!(:colore) { create(:dataset_column, dataset:, code: "colore", role: :input, required: true) }
  let!(:esito) { create(:dataset_column, :target, dataset:, code: "esito", kind: :category, options: %w[ok ko]) }

  it "con un addestramento riuscito crea riga di input e previsione, e accoda il lavoro" do
    training = create(:dataset_training, :done, dataset:)

    result = nil
    expect { result = described_class.call(dataset:, actor:, values: { "colore" => "rosso" }, photos: {}) }
      .to have_enqueued_job(Datasets::PredictJob)

    expect(result).to be_ok
    expect(result.value.training).to eq(training)
    expect(result.value).to be_status_pending
    expect(result.value.input_row).to be_purpose_prediction
    expect(result.value.input_row.value_for("colore")).to eq("rosso")
  end

  it "senza addestramento riuscito → R422-DATASET-005, nessuna riga scritta" do
    create(:dataset_training, dataset:, status: :running)

    result = nil
    expect { result = described_class.call(dataset:, actor:, values: { "colore" => "rosso" }, photos: {}) }
      .to not_change(Datasets::Prediction, :count).and not_change(Datasets::Row, :count)

    expect(result.error.code).to eq("R422-DATASET-005")
  end

  it "dato obbligatorio mancante → l'errore della riga, con i campi in errore" do
    create(:dataset_training, :done, dataset:)

    result = described_class.call(dataset:, actor:, values: {}, photos: {})

    expect(result.error.code).to eq("R422-DATASET-003")
    expect(result.error.details).to include("colore")
  end

  # Il record di previsione nasce insieme alla sua riga: se la creazione fallisce, la riga di input
  # non deve restare nel dataset a fare da domanda senza risposta.
  it "creazione della previsione fallita → nessuna riga di input orfana" do
    create(:dataset_training, :done, dataset:)
    allow(Datasets::PredictJob).to receive(:perform_later).and_raise(StandardError, "coda non disponibile")

    expect { described_class.call(dataset:, actor:, values: { "colore" => "rosso" }, photos: {}) }
      .to raise_error(StandardError, "coda non disponibile")

    expect(Datasets::Prediction.count).to eq(0)
    expect(dataset.rows.purpose_prediction).to be_empty
  end
end
