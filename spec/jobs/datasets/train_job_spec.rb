# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::TrainJob do
  let(:dataset) { create(:dataset) }
  let(:training) { create(:dataset_training, dataset: dataset) }

  it "gira sulla coda :ai (corsia isolata dal monitoraggio real-time)" do
    expect(described_class.new(training).queue_name).to eq("ai")
  end

  describe "concorrenza per dataset (CYRA-246)" do
    it "un solo training per dataset: stesso dataset stessa chiave, dataset diverso chiave diversa" do
      key = described_class.new(training).concurrency_key
      same_dataset = described_class.new(create(:dataset_training, dataset: dataset))
      other_dataset = described_class.new(create(:dataset_training))

      expect(key).to be_present
      expect(key).to eq(same_dataset.concurrency_key)
      expect(key).not_to eq(other_dataset.concurrency_key)
    end

    it "tiene il semaforo per l'intera durata realistica del training, non i 3 minuti di default" do
      expect(described_class.new(training).concurrency_duration).to be >= 1.hour
    end

    # CYRA-791 — la soglia oltre cui un addestramento è dichiarato interrotto e la durata del semaforo
    # sono lo STESSO numero, per costruzione: scaduto il semaforo, Solid Queue lascerebbe comunque
    # partire un secondo lavoro sullo stesso insieme di dati. Due valori scritti a mano che si
    # allontanano riaprirebbero, da un lato o dall'altro, il doppio costo o il blocco eterno.
    it "la durata del semaforo è la stessa soglia oltre cui un addestramento è dichiarato interrotto" do
      expect(described_class.new(training).concurrency_duration).to eq(Datasets::Constants::TRAINING_STALE_AFTER)
    end
  end

  describe "#perform" do
    it "delega l'esecuzione a Trainings::Run" do
      expect(Datasets::Trainings::Run).to receive(:call).with(training: training)

      described_class.perform_now(training)
    end

    it "un'eccezione inattesa marca il training failed senza ritentare (evita di ripagare l'LLM)" do
      allow(Datasets::Trainings::Run).to receive(:call).and_raise(StandardError, "boom")

      described_class.perform_now(training)

      expect(training.reload).to be_status_failed
      expect(training.error_code).to eq("R500-SYSTEM-001")
    end
  end
end
