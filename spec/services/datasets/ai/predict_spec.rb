# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::Ai::Predict do
  let(:dataset) { create(:dataset) }
  let!(:foto) { create(:dataset_column, :photo, dataset: dataset, code: "foto") }
  let!(:titolo) { create(:dataset_column, dataset: dataset, code: "titolo", role: :input, kind: :text) }
  let!(:esito) { create(:dataset_column, :target, dataset: dataset, code: "esito", kind: :category, options: %w[ok ko]) }
  let!(:paid) { create(:dataset_column, :target, dataset: dataset, code: "paid", kind: :boolean) }
  let(:row) do
    record = create(:dataset_row, dataset: dataset, cell_values: { "titolo" => "Festa" })
    create(:dataset_cell, dataset: dataset, row: record, column: foto)
    record
  end

  # Client fittizio: con `response_schema` il client restituisce l'Hash già parsato.
  def client_returning(payload)
    Class.new do
      define_method(:initialize) { |value| @value = value }
      define_method(:generate_content) { |**| @value }
    end.new(payload)
  end

  # Il formato delle immagini è il punto in cui un errore NON si vede: una parte che il client non
  # riconosce viene ignorata, il modello predice sul solo testo e il dataset sembra funzionare
  # peggio invece che rotto (CYRA-594).
  it "manda le foto delle celle come inline_data, non come data URL" do
    captured = nil
    client = Class.new do
      define_method(:initialize) { |sink| @sink = sink }
      define_method(:generate_content) do |contents:, **|
        @sink.call(contents)
        { "esito" => "ok", "paid" => true }
      end
    end.new(->(contents) { captured = contents })

    described_class.call(system_prompt: "P", row: row, input_columns: [ foto, titolo ],
                         target_columns: [ esito, paid ],
                         client: client)

    image = captured.first[:parts].find { |part| part.key?(:inline_data) }
    expect(image).to be_present
    expect(image[:inline_data][:mime_type]).to start_with("image/")
    expect(image[:inline_data][:data]).to be_present
    expect(captured.first[:parts].none? { |part| part[:type] == "image_url" }).to be(true)
  end

  it "predice i valori dei target (coerce a stringhe, keyed per code)" do
    result = described_class.call(system_prompt: "Predici.", row: row,
                                  input_columns: [ foto, titolo ], target_columns: [ esito, paid ],
                                  client: client_returning("esito" => "ok", "paid" => true))

    expect(result).to be_ok
    expect(result.value).to eq("esito" => "ok", "paid" => "true")
  end

  it "propaga l'errore del gateway (Result.err col codice)" do
    erroring = Class.new do
      def generate_content(**)
        raise ::Ai::Llm::Client::Error.new("giù", code: "R502-LLM-001")
      end
    end.new

    result = described_class.call(system_prompt: "P", row: row,
                                  input_columns: [ foto, titolo ], target_columns: [ esito, paid ],
                                  client: erroring)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-LLM-001")
  end

  # CYRA-765 — la chiamata la paga il sistema: quel che può mancare è la configurazione del server AI.
  it "col server AI non configurato dice cosa manca invece di sollevare" do
    allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError, "AI_API_KEY vuota")

    result = described_class.call(system_prompt: "P", row: row, input_columns: [ foto, titolo ],
                                  target_columns: [ esito, paid ])

    expect(result).to be_err
    expect(result.error.code).to eq("R502-LLM-002")
  end

  it "risposta che non è un oggetto → R502-DATASET-002" do
    malformed = Class.new { def generate_content(**) = [ "non un oggetto" ] }.new

    result = described_class.call(system_prompt: "P", row: row,
                                  input_columns: [ foto, titolo ], target_columns: [ esito, paid ],
                                  client: malformed)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-DATASET-002")
  end
end
