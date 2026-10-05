# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::Prediction, type: :model do
  describe "enum status" do
    it "definisce gli stati con prefisso" do
      expect(described_class.statuses).to eq("pending" => 0, "running" => 1, "done" => 2, "failed" => 3)
    end
  end

  describe "associazioni" do
    it "richiede una riga di input" do
      prediction = build(:dataset_prediction, input_row: nil)
      expect(prediction).not_to be_valid
      expect(prediction.errors[:input_row]).to be_present
    end

    it "accetta un training assente (nullable)" do
      dataset = create(:dataset)
      prediction = build(:dataset_prediction, dataset_record: dataset, training: nil)
      expect(prediction).to be_valid
    end
  end

  describe "tenant integrity" do
    it "rifiuta una riga di input di un altro dataset" do
      prediction = build(:dataset_prediction, dataset_record: create(:dataset),
                                              input_row: create(:dataset_row, :prediction, dataset: create(:dataset)))
      expect(prediction).not_to be_valid
      expect(prediction.errors[:input_row]).to be_present
    end

    it "rifiuta un training di un altro dataset" do
      prediction = build(:dataset_prediction, dataset_record: create(:dataset),
                                              training: create(:dataset_training, dataset: create(:dataset)))
      expect(prediction).not_to be_valid
      expect(prediction.errors[:training]).to be_present
    end
  end

  describe "#finish_ok!" do
    it "salva i valori predetti marcando done" do
      prediction = create(:dataset_prediction, status: :running)
      prediction.finish_ok!(predicted_values: { "esito" => "positivo" })

      expect(prediction.reload).to be_status_done
      expect(prediction.predicted_values).to eq("esito" => "positivo")
    end
  end

  describe "#finish_err!" do
    it "salva codice e messaggio marcando failed" do
      prediction = create(:dataset_prediction, status: :running)
      prediction.finish_err!(code: "R502-DATASET-002", message: "Predizione non leggibile")

      expect(prediction.reload).to be_status_failed
      expect(prediction.error_code).to eq("R502-DATASET-002")
    end
  end
end
