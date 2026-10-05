require "rails_helper"

RSpec.describe Secrets::Variables::Rollback do
  let(:project) { create(:project) }
  let(:environment) do
    create(:environment, organization: project.organization).tap { |env| project.environments << env }
  end

  it "ripristina il valore di una versione precedente creando una nuova versione" do
    variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "old").value
    v1 = variable.versions.ordered.last # number 1, valore "old"
    Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "new")

    result = described_class.call(variable: variable.reload, version: v1)

    expect(result).to be_ok
    expect(variable.reload.value).to eq("old")
    # v1(old) + v2(new) + v3(rollback→old)
    expect(variable.versions.count).to eq(3)
  end

  it "rifiuta una versione che appartiene a un altro secret (R422-SECRET-003)" do
    variable = create(:secret_variable)
    other_version = create(:secret_version)

    result = described_class.call(variable:, version: other_version)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-SECRET-003")
  end
end
