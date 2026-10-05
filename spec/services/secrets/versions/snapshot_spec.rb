require "rails_helper"

RSpec.describe Secrets::Versions::Snapshot do
  it "crea la prima versione col valore corrente della variabile" do
    variable = create(:secret_variable, value: "v1")

    version = described_class.call(variable:)

    expect(version.number).to eq(1)
    expect(version.value).to eq("v1")
    expect(version.secret_variable).to eq(variable)
  end

  it "incrementa il number sulle versioni successive" do
    variable = create(:secret_variable, value: "v1")
    described_class.call(variable:)
    variable.update!(value: "v2")

    version = described_class.call(variable:)

    expect(version.number).to eq(2)
    expect(version.value).to eq("v2")
  end

  it "registra created_by dall'actor" do
    actor = create(:account)
    version = described_class.call(variable: create(:secret_variable), actor:)
    expect(version.created_by).to eq(actor)
  end
end
