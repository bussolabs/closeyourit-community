# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::Rows::Save do
  let(:dataset) { create(:dataset) }
  let(:actor) { create(:account) }
  let!(:esito) { create(:dataset_column, :target, dataset: dataset, code: "esito", kind: :category, options: %w[ok ko]) }
  let!(:colore) { create(:dataset_column, dataset: dataset, code: "colore", kind: :text, role: :input, required: true) }
  let!(:foto) { create(:dataset_column, :photo, dataset: dataset, code: "foto", required: false) }

  def png
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/screenshot.png"), "image/png")
  end

  def txt
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/notes.txt"), "text/plain")
  end

  describe "#call — creazione" do
    it "salva i valori scalari nel jsonb (solo i code noti) come riga sample" do
      result = described_class.call(dataset: dataset, actor: actor,
                                    values: { "esito" => "ok", "colore" => "rosso", "ignoto" => "x" }, photos: {})

      expect(result).to be_ok
      row = result.value
      expect(row).to be_purpose_sample
      expect(row.cell_values).to eq("esito" => "ok", "colore" => "rosso")
    end

    it "allega la foto come cella (blob ActiveStorage)" do
      result = described_class.call(dataset: dataset, actor: actor,
                                    values: { "esito" => "ok", "colore" => "rosso" }, photos: { "foto" => png })

      expect(result).to be_ok
      cell = result.value.cells.detect { |c| c.column_id == foto.id }
      expect(cell.image).to be_attached
    end

    it "feature required mancante → R422 con il campo nei details" do
      result = described_class.call(dataset: dataset, actor: actor, values: { "esito" => "ok" }, photos: {})

      expect(result).to be_err
      expect(result.error.code).to eq("R422-DATASET-003")
      expect(result.error.details).to have_key("colore")
    end

    it "target mancante su riga sample → R422 (i target sono le etichette)" do
      result = described_class.call(dataset: dataset, actor: actor, values: { "colore" => "rosso" }, photos: {})

      expect(result).to be_err
      expect(result.error.details).to have_key("esito")
    end

    it "immagine non ammessa (content-type reale txt) → R422, nessuna riga" do
      expect do
        result = described_class.call(dataset: dataset, actor: actor,
                                      values: { "esito" => "ok", "colore" => "rosso" }, photos: { "foto" => txt })
        expect(result).to be_err
        expect(result.error.code).to eq("R422-DATASET-003")
      end.not_to change(Datasets::Row, :count)
    end

    # CYRA-646 — dal canale CLI `photos[foto]` è un parametro qualsiasi: un nome di file al posto del
    # multipart deve dare il rifiuto leggibile, non un errore del server.
    it "una foto che non è un file → R422, nessuna riga" do
      expect do
        result = described_class.call(dataset: dataset, actor: actor,
                                      values: { "esito" => "ok", "colore" => "rosso" },
                                      photos: { "foto" => "screenshot.png" })
        expect(result).to be_err
        expect(result.error.code).to eq("R422-DATASET-003")
      end.not_to change(Datasets::Row, :count)
    end
  end

  describe "#call — modifica" do
    it "aggiorna i valori scalari della riga esistente" do
      row = described_class.call(dataset: dataset, actor: actor,
                                 values: { "esito" => "ok", "colore" => "rosso" }, photos: {}).value

      result = described_class.call(dataset: dataset, actor: actor, row: row,
                                    values: { "esito" => "ko", "colore" => "blu" }, photos: {})

      expect(result).to be_ok
      expect(row.reload.cell_values).to eq("esito" => "ko", "colore" => "blu")
    end
  end
end
