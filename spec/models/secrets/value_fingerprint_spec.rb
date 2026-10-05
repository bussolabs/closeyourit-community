# frozen_string_literal: true

require "rails_helper"

# CYRA-777 — l'impronta del valore è la stessa regola su due tabelle: le variabili di progetto e i
# valori dell'organizzazione. Vive in un callback e non nei service perché è una funzione del valore,
# non una decisione: un percorso di scrittura che se ne dimenticasse farebbe proporre di consolidare
# valori che non sono più uguali, senza nessun errore.
RSpec.describe "L'impronta del valore di un segreto" do
  let(:organization) { create(:organization) }
  let(:environment) { create(:environment, organization:) }
  let(:project) { create(:project, organization:) }

  before { create(:project_environment, project:, environment:) }

  describe "sulla variabile di progetto" do
    it "si scrive alla creazione" do
      variable = create(:secret_variable, project:, organization:, environment:, value: "valore-lungo-abbastanza")

      expect(variable.value_fingerprint).to eq(Secrets::Consolidation::Fingerprint.for("valore-lungo-abbastanza"))
    end

    it "si riscrive quando il valore cambia" do
      variable = create(:secret_variable, project:, organization:, environment:, value: "valore-lungo-abbastanza")

      expect { variable.update!(value: "un-altro-valore-lungo") }.to change { variable.reload.value_fingerprint }
      expect(variable.value_fingerprint).to eq(Secrets::Consolidation::Fingerprint.for("un-altro-valore-lungo"))
    end

    it "resta la stessa se cambia solo la descrizione" do
      variable = create(:secret_variable, project:, organization:, environment:, value: "valore-lungo-abbastanza")

      expect { variable.update!(description: "nuova") }.not_to change { variable.reload.value_fingerprint }
    end

    it "sparisce se il valore scende sotto la soglia" do
      variable = create(:secret_variable, project:, organization:, environment:, value: "valore-lungo-abbastanza")

      variable.update!(value: "corto")

      expect(variable.reload.value_fingerprint).to be_nil
    end

    it "non c'è sul valore vuoto" do
      variable = create(:secret_variable, project:, organization:, environment:, value: "")

      expect(variable.value_fingerprint).to be_nil
    end

    # È il senso stesso della colonna: due progetti diversi con lo stesso valore devono risultare
    # uguali in SQL, dove i due ciphertext non lo sono mai.
    it "è la stessa per due progetti che tengono lo stesso valore" do
      altro = create(:project, organization:)
      create(:project_environment, project: altro, environment:)

      una = create(:secret_variable, project:, organization:, environment:, name: "API_KEY", value: "valore-condiviso-lungo")
      altra = create(:secret_variable, project: altro, organization:, environment:, name: "CHIAVE", value: "valore-condiviso-lungo")

      expect(una.value_fingerprint).to eq(altra.value_fingerprint)
      expect(una.reload.read_attribute_before_type_cast(:value))
        .not_to eq(altra.reload.read_attribute_before_type_cast(:value))
    end
  end

  describe "sul valore dell'organizzazione" do
    it "si scrive al salvataggio e cambia con la rotazione" do
      value = Secrets::Shared::Save.call(organization:, environment:, name: "API_KEY", value: "valore-lungo-abbastanza").value

      expect(value.value_fingerprint).to eq(Secrets::Consolidation::Fingerprint.for("valore-lungo-abbastanza"))

      ruotato = Secrets::Shared::Save.call(organization:, environment:, name: "API_KEY", value: "valore-nuovo-lungo",
                                           skip_confirmation: true).value
      expect(ruotato.reload.value_fingerprint).to eq(Secrets::Consolidation::Fingerprint.for("valore-nuovo-lungo"))
    end

    it "combacia con quella della variabile di progetto che tiene lo stesso valore" do
      value = Secrets::Shared::Save.call(organization:, environment:, name: "API_KEY", value: "valore-condiviso-lungo").value
      variable = create(:secret_variable, project:, organization:, environment:, value: "valore-condiviso-lungo")

      expect(value.value_fingerprint).to eq(variable.value_fingerprint)
    end
  end
end
