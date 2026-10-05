# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::Trainings::Run do
  let(:dataset) { create(:dataset) }
  let!(:foto) { create(:dataset_column, :photo, dataset: dataset, code: "foto") }
  let!(:esito) { create(:dataset_column, :target, dataset: dataset, code: "esito", kind: :category, options: %w[ok ko]) }
  let(:training) { create(:dataset_training, dataset: dataset) }

  before do
    3.times do
      row = create(:dataset_row, dataset: dataset, purpose: :sample, cell_values: { "esito" => "ok" })
      create(:dataset_cell, dataset: dataset, row: row, column: foto)
    end
  end

  # Client scriptato. I due passaggi si distinguono dallo schema chiesto: chi vuole system_prompt
  # sta generando il prompt, chiunque altro sta predicendo.
  def scripted(prompt:, prediction:)
    Class.new do
      define_method(:initialize) { |pr, pd| @prompt = pr; @prediction = pd }
      define_method(:generate_content) do |response_schema:, **|
        response_schema[:properties].key?(:system_prompt) ? { "system_prompt" => @prompt } : @prediction
      end
    end.new(prompt, prediction)
  end

  it "genera il prompt, valuta e marca il training done + il dataset trained" do
    result = described_class.call(training: training, client: scripted(prompt: "Predici l'esito.", prediction: { "esito" => "ok" }))

    expect(result).to be_ok
    expect(training.reload).to be_status_done
    expect(training.system_prompt).to eq("Predici l'esito.")
    expect(training.metrics["overall_accuracy"]).to eq(1.0)
    expect(dataset.reload).to be_status_trained
  end

  it "righe sample insufficienti → training failed R422-DATASET-004" do
    Datasets::Row.where(dataset: dataset).destroy_all

    result = described_class.call(training: training, client: scripted(prompt: "p", prediction: {}))

    expect(result).to be_err
    expect(result.error.code).to eq("R422-DATASET-004")
    expect(training.reload).to be_status_failed
  end

  it "gateway giù → training failed (mai eccezione fuori)" do
    erroring = Class.new do
      def generate_content(**)
        raise ::Ai::Llm::Client::Error.new("giù", code: "R502-LLM-001")
      end
    end.new

    result = described_class.call(training: training, client: erroring)

    expect(result).to be_err
    expect(training.reload).to be_status_failed
  end

  it "nessuna colonna input → training failed R422-DATASET-004 (no_input)" do
    bare = create(:dataset)
    create(:dataset_column, :target, dataset: bare, code: "esito", kind: :category, options: %w[ok ko])
    3.times { create(:dataset_row, dataset: bare, purpose: :sample, cell_values: { "esito" => "ok" }) }
    bare_training = create(:dataset_training, dataset: bare)

    result = described_class.call(training: bare_training, client: scripted(prompt: "p", prediction: {}))

    expect(result).to be_err
    expect(result.error.code).to eq("R422-DATASET-004")
    expect(bare_training.reload).to be_status_failed
  end

  it "idempotente: un training non pending non viene rieseguito (mai chiama il gateway)" do
    training.update!(status: :done, system_prompt: "già fatto")
    exploding = Class.new { def generate_content(**) = raise("il gateway non deve essere chiamato") }.new

    result = described_class.call(training: training, client: exploding)

    expect(result).to be_ok
    expect(training.reload).to be_status_done
    expect(training.system_prompt).to eq("già fatto")
  end

  # CYRA-791 — la presa in carico è la porta: fra il controllo e la transizione può infilarsi un'altra
  # consegna dello stesso lavoro (Solid Queue è at-least-once) e due esecuzioni pagherebbero entrambe
  # il loop LLM. Qui l'istanza in mano al servizio è VECCHIA — dice ancora `pending` — mentre nel
  # database qualcun altro ha già preso in carico: è esattamente ciò che vede il secondo arrivato.
  it "se un altro processo ha già preso in carico l'addestramento, non lo riesegue" do
    stale_view = Datasets::Training.find(training.id)
    Datasets::Training.where(id: training.id).update_all(status: Datasets::Training.statuses[:running])
    exploding = Class.new { def generate_content(**) = raise("il gateway non deve essere chiamato") }.new

    result = described_class.call(training: stale_view, client: exploding)

    expect(result).to be_ok
    expect(training.reload).to be_status_running
  end

  # CYRA-791 — chi sta lavorando lo dice. Senza battito, un addestramento vivo ma lento sarebbe
  # indistinguibile da uno morto col processo, e il recupero automatico ne farebbe partire un secondo.
  describe "segno di vita" do
    it "batte all'avvio e a ogni giro di raffinamento" do
      battiti = []
      allow_any_instance_of(Datasets::Training).to receive(:beat!) { battiti << Time.current }

      described_class.call(training: training,
                           client: scripted(prompt: "Predici l'esito.", prediction: { "esito" => "ko" }))

      expect(training.reload.heartbeat_at).to be_present
      expect(battiti.size).to eq(Datasets::Constants::MAX_ITERATIONS)
    end
  end

  describe "#split (partizione disgiunta few-shot/holdout)" do
    subject(:service) { described_class.new(training: training) }

    it "tiene few-shot e holdout disgiunti con poche righe (N=3)" do
      fewshot, holdout = service.send(:split, (1..3).to_a)

      expect(fewshot & holdout).to be_empty
      expect(fewshot).not_to be_empty
      expect(holdout).not_to be_empty
    end

    it "tiene few-shot e holdout disgiunti a N=8 (banda critica del vecchio bug di leakage)" do
      fewshot, holdout = service.send(:split, (1..8).to_a)

      expect(fewshot & holdout).to be_empty
      expect(fewshot).not_to be_empty
      expect(holdout).not_to be_empty
    end
  end
end
