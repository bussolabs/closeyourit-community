# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::Save do
  let(:org) { create(:organization) }
  let(:actor) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before { create(:membership, account: actor, organization: org, role: :owner) }

  def params(overrides = {})
    {
      project_id: project.id, name: "DS", description: "descrizione",
      columns: [
        { label: "Foto", kind: "photo", role: "input" },
        { label: "Colore", kind: "text", role: "input", required: "1" },
        { label: "Esito", kind: "category", role: "target", options: "ok, ko" },
        { label: "A pagamento", kind: "boolean", role: "target" }
      ]
    }.merge(overrides)
  end

  describe "#call — creazione" do
    it "crea il dataset con input e più target (code derivati dalla label)" do
      result = described_class.call(organization: org, actor: actor, params: params)

      expect(result).to be_ok
      dataset = result.value
      expect(dataset.input_columns.map(&:code)).to contain_exactly("foto", "colore")
      expect(dataset.target_columns.map(&:code)).to contain_exactly("esito", "a_pagamento")
      esito = dataset.target_columns.find { |c| c.code == "esito" }
      expect(esito.kind).to eq("category")
      expect(esito.option_values).to eq(%w[ok ko])
      expect(dataset.input_columns.find { |c| c.code == "foto" }.kind_photo?).to be(true)
    end

    it "una colonna photo marcata target viene coerce a input" do
      spec = params(columns: [ { label: "Foto", kind: "photo", role: "target" },
                               { label: "Esito", kind: "text", role: "target" } ])
      result = described_class.call(organization: org, actor: actor, params: spec)

      expect(result).to be_ok
      expect(result.value.columns.find(&:kind_photo?).role_input?).to be(true)
    end

    it "senza colonne input → R422-DATASET-001" do
      spec = params(columns: [ { label: "Esito", kind: "text", role: "target" } ])
      result = described_class.call(organization: org, actor: actor, params: spec)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-DATASET-001")
    end

    it "senza colonne target → R422-DATASET-001" do
      spec = params(columns: [ { label: "Foto", kind: "photo", role: "input" } ])
      result = described_class.call(organization: org, actor: actor, params: spec)

      expect(result).to be_err
    end

    it "progetto non visibile → R404-DATASET-001" do
      result = described_class.call(organization: org, actor: actor, params: params(project_id: create(:project).id))

      expect(result.error.code).to eq("R404-DATASET-001")
    end

    it "nome vuoto → R422 e nessun dataset (rollback)" do
      result = nil
      expect { result = described_class.call(organization: org, actor: actor, params: params(name: "")) }
        .not_to change(Datasets::Dataset, :count)
      expect(result.error.code).to eq("R422-DATASET-001")
    end

    it "registra un evento 'created' nell'activity-log generalizzato" do
      expect do
        result = described_class.call(organization: org, actor: actor, params: params)
        expect(result).to be_ok

        event = result.value.activity_events.last
        expect(event.action).to eq("created")
        expect(event.organization_id).to eq(org.id)
      end.to change(Activity::Event, :count).by(1)
    end

    it "target category senza valori → R422 (rollback)" do
      spec = params(columns: [ { label: "Foto", kind: "photo", role: "input" },
                               { label: "Esito", kind: "category", role: "target", options: "" } ])
      result = nil
      expect { result = described_class.call(organization: org, actor: actor, params: spec) }
        .not_to change(Datasets::Dataset, :count)
      expect(result.error.code).to eq("R422-DATASET-001")
    end
  end

  describe "#call — modifica" do
    it "senza righe: sostituisce le colonne" do
      dataset = described_class.call(organization: org, actor: actor, params: params).value

      result = described_class.call(organization: org, actor: actor, dataset: dataset,
                                    params: params(name: "DS2", columns: [ { label: "Img", kind: "photo", role: "input" },
                                                                           { label: "Peso", kind: "number", role: "target" } ]))

      expect(result).to be_ok
      expect(dataset.reload.name).to eq("DS2")
      expect(dataset.target_columns.map(&:code)).to eq(%w[peso])
    end

    it "con righe: blocca le colonne, aggiorna solo nome/descrizione" do
      dataset = described_class.call(organization: org, actor: actor, params: params).value
      create(:dataset_row, dataset: dataset, purpose: :sample)

      result = described_class.call(organization: org, actor: actor, dataset: dataset,
                                    params: params(name: "DS3", columns: [ { label: "Peso", kind: "number", role: "target" } ]))

      expect(result).to be_ok
      expect(dataset.reload.name).to eq("DS3")
      expect(dataset.target_columns.map(&:code)).to contain_exactly("esito", "a_pagamento")
    end

    it "registra 'updated' quando cambia il nome (colonna propria)" do
      dataset = described_class.call(organization: org, actor: actor, params: params).value

      expect do
        described_class.call(organization: org, actor: actor, dataset: dataset, params: params(name: "DS2"))
      end.to change(Activity::Event, :count).by(1)

      event = dataset.activity_events.chronological.last
      expect(event.action).to eq("updated")
      expect(event.data["fields"]).to include("name")
    end

    # CYRA-646 — dal canale CLI si modifica per campi presenti: senza la chiave `columns` lo schema
    # non si tocca. La lista vuota resta un errore (un dataset senza input e senza target non esiste).
    it "params senza la chiave columns: lascia lo schema com'è" do
      dataset = described_class.call(organization: org, actor: actor, params: params).value

      result = described_class.call(organization: org, actor: actor, dataset: dataset,
                                    params: { name: "DS4", description: "altra" })

      expect(result).to be_ok
      expect(dataset.reload.name).to eq("DS4")
      expect(dataset.columns.ordered.map(&:code)).to eq(%w[foto colore esito a_pagamento])
    end

    it "params con columns vuoto: rifiuta, lo schema resta quello di prima" do
      dataset = described_class.call(organization: org, actor: actor, params: params).value

      result = described_class.call(organization: org, actor: actor, dataset: dataset,
                                    params: { name: "DS5", columns: [] })

      expect(result).to be_err
      expect(result.error.code).to eq("R422-DATASET-001")
      expect(dataset.reload.columns.count).to eq(4)
    end

    it "NON registra 'updated' se cambia solo lo schema colonne (nessuna colonna propria toccata)" do
      dataset = described_class.call(organization: org, actor: actor, params: params).value

      expect do
        described_class.call(organization: org, actor: actor, dataset: dataset,
                             params: params(columns: [ { label: "Img", kind: "photo", role: "input" },
                                                       { label: "Peso", kind: "number", role: "target" } ]))
      end.not_to change(Activity::Event, :count)
    end
  end
end
