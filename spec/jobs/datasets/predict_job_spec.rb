# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::PredictJob do
  let(:dataset) { create(:dataset) }
  let(:prediction) { create(:dataset_prediction, dataset_record: dataset) }

  it "gira sulla coda :ai (corsia isolata dal monitoraggio real-time)" do
    expect(described_class.new(prediction).queue_name).to eq("ai")
  end

  describe "concorrenza per dataset (CYRA-246)" do
    it "una sola predizione per dataset: stesso dataset stessa chiave, dataset diverso chiave diversa" do
      key = described_class.new(prediction).concurrency_key
      same_dataset = described_class.new(create(:dataset_prediction, dataset_record: dataset))
      other_dataset = described_class.new(create(:dataset_prediction))

      expect(key).to be_present
      expect(key).to eq(same_dataset.concurrency_key)
      expect(key).not_to eq(other_dataset.concurrency_key)
    end

    it "tiene il semaforo oltre i 3 minuti di default (una predizione può durare di più)" do
      expect(described_class.new(prediction).concurrency_duration).to be > 3.minutes
    end
  end

  describe "#perform" do
    it "delega l'esecuzione a Predictions::Predict" do
      expect(Datasets::Predictions::Predict).to receive(:call).with(prediction: prediction)

      described_class.perform_now(prediction)
    end

    it "un'eccezione inattesa marca la predizione failed senza ritentare (evita di ripagare l'LLM)" do
      allow(Datasets::Predictions::Predict).to receive(:call).and_raise(StandardError, "boom")

      described_class.perform_now(prediction)

      expect(prediction.reload).to be_status_failed
      expect(prediction.error_code).to eq("R500-SYSTEM-001")
    end
  end
end
