# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::Dataset, type: :model do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }

  describe "validazioni" do
    it "è valida con progetto e nome" do
      expect(build(:dataset, project: project)).to be_valid
    end

    it "rifiuta il nome mancante (anche solo spazi, via normalizes)" do
      dataset = build(:dataset, project: project, name: "   ")
      expect(dataset).not_to be_valid
      expect(dataset.errors[:name]).to be_present
    end
  end

  describe "normalizzazioni" do
    it "rimuove gli spazi da nome e descrizione" do
      dataset = build(:dataset, name: "  Foto difetti  ", description: "  note  ")
      expect(dataset.name).to eq("Foto difetti")
      expect(dataset.description).to eq("note")
    end
  end

  describe "enum status" do
    it "definisce solo draft e trained (nessuno stato intermedio, gap a 1 voluto)" do
      expect(described_class.statuses).to eq("draft" => 0, "trained" => 2)
    end

    it "il default è draft" do
      expect(described_class.new.status).to eq("draft")
    end

    it "espone i predicati con prefisso" do
      expect(build(:dataset, status: :trained)).to be_status_trained
    end
  end

  describe "attr_readonly :project_id" do
    it "vieta il cambio di progetto dopo la creazione" do
      dataset = create(:dataset, project: project)
      other = create(:project, organization: organization)

      expect { dataset.update(project_id: other.id) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(dataset.reload.project_id).to eq(project.id)
    end
  end

  describe "#organization_id" do
    it "delega al progetto (radice di tenancy)" do
      dataset = create(:dataset, project: project)
      expect(dataset.organization_id).to eq(organization.id)
    end
  end

  describe "#input_columns / #target_columns" do
    it "restituisce gli input e i target ordinati (più target ammessi)" do
      dataset = create(:dataset)
      input_b = create(:dataset_column, dataset: dataset, role: :input, position: 2)
      input_a = create(:dataset_column, dataset: dataset, role: :input, position: 1)
      target = create(:dataset_column, :target, dataset: dataset, position: 3)

      expect(dataset.reload.input_columns).to eq([ input_a, input_b ])
      expect(dataset.target_columns).to eq([ target ])
    end
  end

  describe "dependent: :destroy" do
    it "distrugge colonne, righe, training e predizioni collegate" do
      dataset = create(:dataset)
      create(:dataset_column, dataset: dataset)
      # La factory :dataset_prediction crea anche il training e l'input_row (purpose=prediction) sul dataset.
      create(:dataset_prediction, dataset_record: dataset)

      expect { dataset.destroy }
        .to change(Datasets::Column, :count).by(-1)
        .and change(Datasets::Row, :count).by(-1)
        .and change(Datasets::Training, :count).by(-1)
        .and change(Datasets::Prediction, :count).by(-1)
    end
  end

  describe "factory" do
    it "produce un record valido" do
      expect(create(:dataset)).to be_persisted
    end
  end
end
