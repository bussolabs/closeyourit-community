# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::Ai::BuildPrompt do
  let(:dataset) { create(:dataset) }
  let!(:foto) { create(:dataset_column, :photo, dataset: dataset, code: "foto") }
  let!(:esito) { create(:dataset_column, :target, dataset: dataset, code: "esito", kind: :category, options: %w[ok ko]) }

  # 7 righe con foto → 7 immagini candidate: oltre il cap MAX_INLINE_IMAGES (6).
  let(:examples) do
    Array.new(7) do
      row = create(:dataset_row, dataset: dataset, purpose: :sample, cell_values: { "esito" => "ok" })
      create(:dataset_cell, dataset: dataset, row: row, column: foto)
      row.reload
    end
  end

  def build_prompt(client)
    described_class.call(dataset: dataset, examples: examples, input_columns: [ foto ],
                         target_columns: [ esito ], client: client)
  end

  # Client fittizio nella forma content-based del gateway Qwen.
  def client_returning(payload)
    Class.new do
      define_method(:initialize) { |value| @value = value }
      define_method(:generate_content) { |**| @value }
    end.new(payload)
  end

  it "genera il system prompt via tool submit_prompt" do
    result = build_prompt(client_returning("system_prompt" => "Predici l'esito dalla foto."))

    expect(result).to be_ok
    expect(result.value).to eq("Predici l'esito dalla foto.")
  end

  it "prompt vuoto nella risposta → R502-DATASET-002 (illeggibile)" do
    result = build_prompt(client_returning("system_prompt" => "   "))

    expect(result).to be_err
    expect(result.error.code).to eq("R502-DATASET-002")
  end

  it "risposta che non è un oggetto → R502-DATASET-002 (illeggibile)" do
    malformed = Class.new { def generate_content(**) = [ "non un oggetto" ] }.new

    result = build_prompt(malformed)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-DATASET-002")
  end

  it "errore del gateway → propaga il codice (Result.err)" do
    erroring = Class.new { def generate_content(**) = raise(::Ai::Llm::Client::Error.new("giù", code: "R502-LLM-004")) }.new

    result = build_prompt(erroring)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-LLM-004")
  end

  # CYRA-765 — chiave e indirizzo del server AI vengono da ENV: se mancano, l'esito è un errore
  # leggibile e non un 500.
  it "col server AI non configurato dice cosa manca invece di sollevare" do
    allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError, "AI_API_KEY vuota")

    result = described_class.call(dataset: dataset, examples: examples, input_columns: [ foto ],
                                  target_columns: [ esito ])

    expect(result).to be_err
    expect(result.error.code).to eq("R502-LLM-002")
    expect(result.error.status).to eq(:bad_gateway)
  end

  # Il formato conta quanto il numero: una parte che il client non riconosce sparisce in silenzio, e
  # il prompt verrebbe generato senza aver mai visto le foto degli esempi (CYRA-594).
  it "cap immagini inline: al massimo MAX_INLINE_IMAGES parti inline_data" do
    client = Class.new do
      attr_reader :contents
      define_method(:generate_content) do |contents:, **|
        @contents = contents
        { "system_prompt" => "P" }
      end
    end.new

    build_prompt(client)

    images = client.contents.first[:parts].select { |part| part.key?(:inline_data) }
    expect(images.size).to eq(Datasets::Constants::MAX_INLINE_IMAGES)
    expect(images).to all(satisfy { |part| part[:inline_data][:mime_type] == "image/png" })
    expect(images).to all(satisfy { |part| part[:inline_data][:data].present? })
  end
end
