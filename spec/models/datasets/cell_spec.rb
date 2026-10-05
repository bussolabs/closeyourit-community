# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::Cell, type: :model do
  let(:dataset) { create(:dataset) }
  let(:photo_column) { create(:dataset_column, :photo, dataset: dataset) }
  let(:row) { create(:dataset_row, dataset: dataset) }

  describe "validazioni" do
    it "è valida con riga, colonna foto dello stesso dataset e immagine ammessa" do
      expect(build(:dataset_cell, dataset: dataset, row: row, column: photo_column)).to be_valid
    end

    it "rifiuta una colonna non-photo" do
      text_column = create(:dataset_column, dataset: dataset, kind: :text)
      cell = build(:dataset_cell, dataset: dataset, row: row, column: text_column)
      expect(cell).not_to be_valid
      expect(cell.errors[:column]).to be_present
    end

    it "rifiuta riga e colonna di dataset diversi (tenant integrity)" do
      other_column = create(:dataset_column, :photo, dataset: create(:dataset))
      cell = build(:dataset_cell, row: row, column: other_column)
      expect(cell).not_to be_valid
      expect(cell.errors[:column]).to be_present
    end

    it "rifiuta una seconda cella per la stessa (riga, colonna)" do
      create(:dataset_cell, dataset: dataset, row: row, column: photo_column)
      dupe = build(:dataset_cell, dataset: dataset, row: row, column: photo_column)
      expect(dupe).not_to be_valid
      expect(dupe.errors[:column_id]).to be_present
    end

    it "rifiuta un content-type non ammesso" do
      cell = build(:dataset_cell, dataset: dataset, row: row, column: photo_column)
      cell.image.attach(io: StringIO.new("testo"), filename: "note.txt", content_type: "text/plain")
      expect(cell).not_to be_valid
      expect(cell.errors[:image]).to be_present
    end
  end

  describe ".allowed?" do
    it "accetta un raster ammesso di dimensione valida" do
      expect(described_class.allowed?(content_type: "image/png", byte_size: 1_000)).to be(true)
    end

    it "rifiuta un content-type non in allowlist" do
      expect(described_class.allowed?(content_type: "image/svg+xml", byte_size: 1_000)).to be(false)
    end

    it "rifiuta un file vuoto e uno oltre il limite" do
      expect(described_class.allowed?(content_type: "image/png", byte_size: 0)).to be(false)
      over = Datasets::Constants::IMAGE_MAX_SIZE + 1
      expect(described_class.allowed?(content_type: "image/png", byte_size: over)).to be(false)
    end
  end
end
