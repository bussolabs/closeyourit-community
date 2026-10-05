# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::Predictions::Predict do
  let(:dataset) { create(:dataset) }
  let!(:foto) { create(:dataset_column, :photo, dataset: dataset, code: "foto") }
  let!(:esito) { create(:dataset_column, :target, dataset: dataset, code: "esito", kind: :category, options: %w[ok ko]) }
  let(:training) { create(:dataset_training, :done, dataset: dataset, system_prompt: "Predici l'esito.") }
  let(:input_row) do
    record = create(:dataset_row, dataset: dataset, purpose: :prediction, cell_values: {})
    create(:dataset_cell, dataset: dataset, row: record, column: foto)
    record
  end
  let(:prediction) { create(:dataset_prediction, dataset_record: dataset, training: training, input_row: input_row) }

  def client_returning(payload)
    Class.new do
      define_method(:initialize) { |value| @value = value }
      define_method(:generate_content) { |**| @value }
    end.new(payload)
  end

  it "salva i valori predetti marcando done" do
    result = described_class.call(prediction: prediction, client: client_returning("esito" => "ok"))

    expect(result).to be_ok
    expect(prediction.reload).to be_status_done
    expect(prediction.predicted_values).to eq("esito" => "ok")
  end

  it "senza training completato → R422-DATASET-005 e prediction failed" do
    untrained = create(:dataset_prediction, dataset_record: dataset, training: nil, input_row: input_row)

    result = described_class.call(prediction: untrained, client: client_returning({}))

    expect(result.error.code).to eq("R422-DATASET-005")
    expect(untrained.reload).to be_status_failed
  end

  it "gateway giù → prediction failed (mai eccezione fuori)" do
    erroring = Class.new do
      def generate_content(**)
        raise ::Ai::Llm::Client::Error.new("giù", code: "R502-LLM-001")
      end
    end.new

    result = described_class.call(prediction: prediction, client: erroring)

    expect(result).to be_err
    expect(prediction.reload).to be_status_failed
  end

  it "idempotente: una prediction non pending non viene rieseguita (mai chiama il gateway)" do
    prediction.update!(status: :done, predicted_values: { "esito" => "ok" })
    exploding = Class.new { def generate_content(**) = raise("il gateway non deve essere chiamato") }.new

    result = described_class.call(prediction: prediction, client: exploding)

    expect(result).to be_ok
    expect(prediction.reload).to be_status_done
    expect(prediction.predicted_values).to eq("esito" => "ok")
  end
end
