# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::Row, type: :model do
  let(:dataset) { create(:dataset) }

  describe "enum purpose" do
    it "definisce sample e prediction con prefisso" do
      expect(described_class.purposes).to eq("sample" => 0, "prediction" => 1)
      expect(build(:dataset_row, :prediction)).to be_purpose_prediction
    end
  end

  describe "#value_for" do
    it "restituisce il valore scalare per column code" do
      row = build(:dataset_row, cell_values: { "prezzo" => "10", "colore" => "rosso" })
      expect(row.value_for(:prezzo)).to eq("10")
      expect(row.value_for("colore")).to eq("rosso")
    end

    it "restituisce nil per una chiave assente e con cell_values vuoto" do
      expect(build(:dataset_row, cell_values: {}).value_for(:mancante)).to be_nil
    end
  end

  describe "cell_values" do
    it "di default è un hash vuoto persistibile" do
      row = create(:dataset_row, dataset: dataset)
      expect(row.reload.cell_values).to eq({})
    end
  end

  describe "dependent: :destroy sulle celle" do
    it "distrugge le celle collegate alla riga" do
      row = create(:dataset_row, dataset: dataset)
      create(:dataset_cell, dataset: dataset, row: row, column: create(:dataset_column, :photo, dataset: dataset))

      expect { row.destroy }.to change(Datasets::Cell, :count).by(-1)
    end
  end
end
