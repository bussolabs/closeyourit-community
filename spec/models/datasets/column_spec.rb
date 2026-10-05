# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::Column, type: :model do
  let(:dataset) { create(:dataset) }

  describe "validazioni" do
    it "è valida con dataset, code e label" do
      expect(build(:dataset_column, dataset: dataset)).to be_valid
    end

    it "rifiuta la label mancante" do
      column = build(:dataset_column, dataset: dataset, label: "  ")
      expect(column).not_to be_valid
      expect(column.errors[:label]).to be_present
    end

    it "rifiuta un code che non inizia con una lettera" do
      column = build(:dataset_column, dataset: dataset, code: "1col")
      expect(column).not_to be_valid
      expect(column.errors[:code]).to be_present
    end

    it "rifiuta un code duplicato nello stesso dataset" do
      create(:dataset_column, dataset: dataset, code: "prezzo")
      dupe = build(:dataset_column, dataset: dataset, code: "prezzo")
      expect(dupe).not_to be_valid
      expect(dupe.errors[:code]).to be_present
    end

    it "consente lo stesso code in dataset diversi" do
      create(:dataset_column, dataset: dataset, code: "prezzo")
      expect(build(:dataset_column, dataset: create(:dataset), code: "prezzo")).to be_valid
    end
  end

  describe "normalizzazione code" do
    it "porta in minuscolo e sostituisce gli spazi con underscore" do
      column = build(:dataset_column, dataset: dataset, code: "  Codice Fiscale ")
      expect(column.code).to eq("codice_fiscale")
    end
  end

  describe "enum kind e role" do
    it "definisce i tipi con prefisso" do
      expect(described_class.kinds).to eq(
        "text" => 0, "number" => 1, "category" => 2, "boolean" => 3, "photo" => 4
      )
    end

    it "definisce i ruoli con prefisso" do
      expect(described_class.roles).to eq("input" => 0, "target" => 1)
      expect(build(:dataset_column, :target)).to be_role_target
    end
  end

  describe "più target ammessi + photo non target" do
    it "consente più colonne target nello stesso dataset (multi-attributo)" do
      create(:dataset_column, :target, dataset: dataset, code: "a")
      expect(build(:dataset_column, :target, dataset: dataset, code: "b")).to be_valid
    end

    it "rifiuta una colonna photo con ruolo target (si predicono scalari, non immagini)" do
      column = build(:dataset_column, :photo, dataset: dataset, role: :target)
      expect(column).not_to be_valid
      expect(column.errors[:role]).to be_present
    end
  end

  describe "kind=category richiede options" do
    it "rifiuta una category senza valori" do
      column = build(:dataset_column, dataset: dataset, kind: :category, options: [])
      expect(column).not_to be_valid
      expect(column.errors[:options]).to be_present
    end

    it "accetta una category con valori" do
      expect(build(:dataset_column, :category, dataset: dataset)).to be_valid
    end

    it "#option_values pulisce spazi e blank" do
      column = build(:dataset_column, kind: :category, options: [ " a ", "", "b" ])
      expect(column.option_values).to eq(%w[a b])
    end
  end

  describe "scope .ordered" do
    it "ordina per position poi label" do
      b = create(:dataset_column, dataset: dataset, position: 2)
      a = create(:dataset_column, dataset: dataset, position: 1)
      expect(dataset.columns.ordered.to_a).to eq([ a, b ])
    end
  end

  describe "dependent: :destroy sulle celle" do
    it "distrugge le celle foto collegate" do
      column = create(:dataset_column, :photo, dataset: dataset)
      create(:dataset_cell, dataset: dataset, column: column, row: create(:dataset_row, dataset: dataset))

      expect { column.destroy }.to change(Datasets::Cell, :count).by(-1)
    end
  end
end
