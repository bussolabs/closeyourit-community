# frozen_string_literal: true

require "rails_helper"

# CYRA-777 — l'alias è ciò che rende accettabile la proposta di consolidamento: il valore si sposta
# nell'organizzazione, ma ogni progetto continua a chiamarlo come lo chiamava, senza rimettere le
# mani nel codice che lo legge. Da qui il vincolo che conta: quello che non deve collidere è il NOME
# EFFETTIVO, cioè quello che il progetto riceve davvero.
RSpec.describe Secrets::Shared::Delegation do
  let(:organization) { create(:organization) }
  let(:environment) { create(:environment, organization:, code: "production") }
  let(:project) { create(:project, organization:) }

  before { create(:project_environment, project:, environment:) }

  let(:shared_value) do
    Secrets::Shared::Save.call(organization:, environment:, name: "api_key", value: "valore-lungo-abbastanza").value
  end

  it "senza alias il progetto vede il nome del secret dell'organizzazione" do
    delegation = shared_value.delegations.create!(project:)

    expect(delegation.effective_name).to eq("API_KEY")
    expect(delegation.name).to eq("API_KEY")
  end

  it "con l'alias il progetto vede il proprio nome, l'organizzazione il suo" do
    delegation = shared_value.delegations.create!(project:, local_name: "chiave_api")

    expect(delegation.effective_name).to eq("CHIAVE_API")
    expect(delegation.name).to eq("API_KEY")
  end

  it "normalizza l'alias in UPPER_SNAKE e rifiuta i nomi fuori formato" do
    delegation = shared_value.delegations.build(project:, local_name: " chiave-api ")

    expect(delegation).not_to be_valid
    expect(delegation.errors[:local_name]).to be_present
  end

  it "rifiuta un alias con un nome riservato" do
    expect(shared_value.delegations.build(project:, local_name: "GITHUB_TOKEN")).not_to be_valid
    expect(shared_value.delegations.build(project:, local_name: "SECRETS_JSON")).not_to be_valid
  end

  describe "collisione col nome effettivo" do
    it "rifiuta l'alias che coincide con un secret locale del progetto" do
      create(:secret_variable, project:, organization:, environment:, name: "DB_URL", value: "valore-lungo-abbastanza")

      delegation = shared_value.delegations.build(project:, local_name: "DB_URL")

      expect(delegation).not_to be_valid
      expect(delegation.errors[:base]).to be_present
    end

    # È il caso che l'alias apre e che prima non poteva esistere: il nome dell'organizzazione è
    # libero, quello che collide è l'alias di un'altra delega.
    it "rifiuta due deleghe che atterrano sullo stesso nome nello stesso ambiente" do
      altro = Secrets::Shared::Save.call(organization:, environment:, name: "altro_valore", value: "un-altro-valore-lungo").value
      altro.delegations.create!(project:, local_name: "CHIAVE_API")

      delegation = shared_value.delegations.build(project:, local_name: "CHIAVE_API")

      expect(delegation).not_to be_valid
      expect(delegation.errors[:base]).to be_present
    end

    it "accetta due deleghe con nomi effettivi diversi" do
      altro = Secrets::Shared::Save.call(organization:, environment:, name: "altro_valore", value: "un-altro-valore-lungo").value
      altro.delegations.create!(project:, local_name: "CHIAVE_API")

      expect(shared_value.delegations.build(project:, local_name: "CHIAVE_DUE")).to be_valid
    end

    # Il nome dell'organizzazione può essere occupato: quello che conta è cosa riceve il progetto.
    it "accetta l'alias quando il progetto ha già un secret locale col nome dell'organizzazione" do
      create(:secret_variable, project:, organization:, environment:, name: "API_KEY", value: "valore-lungo-abbastanza")

      expect(shared_value.delegations.build(project:, local_name: "CHIAVE_API")).to be_valid
    end

    it "non si accusa da sola quando viene risalvata" do
      delegation = shared_value.delegations.create!(project:, local_name: "CHIAVE_API")

      expect(delegation.reload).to be_valid
    end
  end

  describe "il nome che il progetto riceve" do
    it "arriva nel bundle con l'alias, non col nome dell'organizzazione" do
      shared_value.delegations.create!(project:, local_name: "CHIAVE_API")

      bundle = Secrets::Bundle.call(project:, environment:).value

      expect(bundle).to include("CHIAVE_API" => "valore-lungo-abbastanza")
      expect(bundle).not_to have_key("API_KEY")
    end
  end

  describe "il secret locale creato dopo" do
    it "non può prendere il nome effettivo di una delega" do
      shared_value.delegations.create!(project:, local_name: "CHIAVE_API")

      variable = build(:secret_variable, project:, organization:, environment:, name: "CHIAVE_API", value: "valore-lungo-abbastanza")

      expect(variable).not_to be_valid
      expect(variable.errors[:name]).to be_present
    end

    it "può prendere il nome dell'organizzazione se la delega usa un alias" do
      shared_value.delegations.create!(project:, local_name: "CHIAVE_API")

      variable = build(:secret_variable, project:, organization:, environment:, name: "API_KEY", value: "valore-lungo-abbastanza")

      expect(variable).to be_valid
    end
  end
end
