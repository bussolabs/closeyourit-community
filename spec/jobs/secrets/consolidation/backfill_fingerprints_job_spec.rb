# frozen_string_literal: true

require "rails_helper"

# CYRA-777 — senza impronta un valore non entra in nessun raggruppamento, cioè non viene mai
# proposto. Il giro ripara le righe nate prima della colonna e quelle entrate mentre girava una
# versione senza il callback.
RSpec.describe Secrets::Consolidation::BackfillFingerprintsJob do
  let(:organization) { create(:organization) }
  let(:environment) { create(:environment, organization:) }
  let(:project) { create(:project, organization:) }

  before { create(:project_environment, project:, environment:) }

  it "scrive l'impronta mancante sulle variabili di progetto" do
    variable = create(:secret_variable, project:, organization:, environment:, value: "valore-lungo-abbastanza")
    variable.update_columns(value_fingerprint: nil)

    described_class.perform_now

    expect(variable.reload.value_fingerprint).to eq(Secrets::Consolidation::Fingerprint.for("valore-lungo-abbastanza"))
  end

  it "scrive l'impronta mancante sui valori dell'organizzazione" do
    value = Secrets::Shared::Save.call(organization:, environment:, name: "API_KEY", value: "valore-lungo-abbastanza").value
    value.update_columns(value_fingerprint: nil)

    described_class.perform_now

    expect(value.reload.value_fingerprint).to be_present
  end

  it "lascia senza impronta i valori troppo corti, e ripassarci non cambia niente" do
    variable = create(:secret_variable, project:, organization:, environment:, value: "corto")

    expect { described_class.perform_now }.not_to change { variable.reload.value_fingerprint }
    expect(variable.value_fingerprint).to be_nil
  end

  # Le righe storiche possono non passare validazioni nate dopo di loro: il backfill non deve
  # fermarsi lì, perché tutto ciò che viene dopo resterebbe senza impronta.
  it "non si ferma su una riga che non passerebbe le validazioni di oggi" do
    rotta = create(:secret_variable, project:, organization:, environment:, value: "valore-lungo-abbastanza")
    rotta.update_columns(value_fingerprint: nil, name: "nome minuscolo non valido")
    sana = create(:secret_variable, project:, organization:, environment:, name: "SANA", value: "un-altro-valore-lungo")
    sana.update_columns(value_fingerprint: nil)

    described_class.perform_now

    expect(sana.reload.value_fingerprint).to be_present
    expect(rotta.reload.value_fingerprint).to be_present
  end
end
