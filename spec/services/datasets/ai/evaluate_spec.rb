# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::Ai::Evaluate do
  let(:dataset) { create(:dataset) }
  let!(:foto) { create(:dataset_column, :photo, dataset: dataset, code: "foto") }
  let!(:esito) { create(:dataset_column, :target, dataset: dataset, code: "esito", kind: :category, options: %w[ok ko]) }
  let!(:paid) { create(:dataset_column, :target, dataset: dataset, code: "paid", kind: :boolean) }

  def row_with(values)
    record = create(:dataset_row, dataset: dataset, purpose: :sample, cell_values: values)
    create(:dataset_cell, dataset: dataset, row: record, column: foto)
    record
  end

  # Client che predice SEMPRE esito=ok, paid=true (metà giuste sulle due righe sotto).
  def constant_client(payload)
    Class.new do
      define_method(:initialize) { |value| @value = value }
      define_method(:generate_content) { |**| @value }
    end.new(payload)
  end

  it "calcola accuratezza overall e per-target + raccoglie gli errori" do
    correct_row = row_with("esito" => "ok", "paid" => "true")
    wrong_row = row_with("esito" => "ko", "paid" => "false")

    result = described_class.call(system_prompt: "P", rows: [ correct_row, wrong_row ],
                                  input_columns: [ foto ], target_columns: [ esito, paid ],
                                  client: constant_client("esito" => "ok", "paid" => true))

    expect(result).to be_ok
    metrics = result.value
    expect(metrics["overall_accuracy"]).to eq(0.5)
    expect(metrics["per_target"]).to eq("esito" => 0.5, "paid" => 0.5)
    expect(metrics["evaluated"]).to eq(2)
    expect(metrics["mistakes"].map { |m| m["code"] }).to contain_exactly("esito", "paid")
  end

  it "se una Predict fallisce a metà holdout, propaga l'errore (Result.err)" do
    rows = [ row_with("esito" => "ok"), row_with("esito" => "ko") ]
    erroring = Class.new do
      def generate_content(**)
        raise ::Ai::Llm::Client::Error.new("giù", code: "R502-LLM-001")
      end
    end.new

    result = described_class.call(system_prompt: "P", rows: rows,
                                  input_columns: [ foto ], target_columns: [ esito, paid ],
                                  client: erroring)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-LLM-001")
  end
end
