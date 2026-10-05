# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Shared::Rows::Save do
  let(:organization) { create(:organization) }
  let(:actor) { create(:account) }
  let(:env_prod) { create(:environment, organization:, code: "production") }
  let(:env_stg) { create(:environment, organization:, code: "staging") }

  def cell(environment, value) = { environment:, value: }

  def variable = organization.shared_secret_variables.find_by(name: "API_KEY")

  it "crea le celle non-blank e salta quelle vuote" do
    result = described_class.call(organization:, name: "api_key", actor:,
                                  cells: [ cell(env_prod, "prod-secret"), cell(env_stg, "  ") ])

    expect(result).to be_ok
    expect(variable.values.map(&:environment_id)).to contain_exactly(env_prod.id)
    expect(variable.values.first.value).to eq("prod-secret")
  end

  it "rejects a row when all values are blank" do
    result = described_class.call(organization:, name: "api_key",
                                  cells: [ cell(env_prod, ""), cell(env_stg, "   ") ])

    expect(result).to be_err
    expect(result.error.code).to eq("R422-SHARED-001")
    expect(Secrets::Shared::Variable.where(organization:)).to be_empty
  end

  it "cifra i valori salvati" do
    described_class.call(organization:, name: "api_key", cells: [ cell(env_prod, "prod-secret") ])

    expect(variable.values.first.ciphertext_for(:value)).not_to include("prod-secret")
  end

  it "fa rollback dell'intera riga se una cella è invalida (nome riservato)" do
    result = described_class.call(organization:, name: "GITHUB_TOKEN",
                                  cells: [ cell(env_prod, "a"), cell(env_stg, "b") ])

    expect(result).to be_err
    expect(Secrets::Shared::Variable.where(organization:)).to be_empty
  end

  it "ignora ambienti fuori organizzazione senza scritture parziali" do
    foreign_environment = create(:environment)

    result = described_class.call(organization:, name: "api_key",
                                  cells: [ cell(env_prod, "ok"), cell(foreign_environment, "leak") ])

    expect(result).to be_err
    expect(Secrets::Shared::Variable.where(organization:)).to be_empty
  end

  context "con un valore già delegato che cambia" do
    let(:project) { create(:project, organization:) }
    let!(:existing) do
      create(:project_environment, project:, environment: env_prod)
      value = Secrets::Shared::Save.call(organization:, environment: env_prod, name: "api_key", value: "one").value
      Secrets::Shared::Delegate.call(shared_value: value, project:)
      value
    end

    it "richiede la conferma d'impatto quando manca il digest" do
      result = described_class.call(organization:, name: "api_key", cells: [ cell(env_prod, "two") ])

      expect(result).to be_err
      expect(result.error.code).to eq("R409-SHARED-001")
      expect(result.error.details["entries"].first["environment"]).to eq("production")
      expect(existing.reload.value).to eq("one")
    end

    it "applica la riga con il digest aggregato corretto" do
      digest = Secrets::Shared::RowImpact.call(shared_values: [ existing ]).value["digest"]

      result = described_class.call(organization:, name: "api_key",
                                    cells: [ cell(env_prod, "two") ], confirmation_digest: digest)

      expect(result).to be_ok
      expect(existing.reload.value).to eq("two")
    end
  end
end
