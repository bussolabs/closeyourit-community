# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Personal::Variables::Set do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  it "crea la variabile e la prima versione, con evento set" do
    result = described_class.call(account:, organization:, name: "api_key", value: "v1")

    expect(result).to be_ok
    variable = result.value
    expect(variable.name).to eq("API_KEY")
    expect(variable.value).to eq("v1")
    expect(variable.versions.count).to eq(1)
    expect(Secrets::Personal::Event.for(account:, organization:).where(action: "set", name: "API_KEY")).to exist
  end

  it "fa upsert sullo stesso [account, org, nome] senza duplicare" do
    described_class.call(account:, organization:, name: "API_KEY", value: "v1")
    described_class.call(account:, organization:, name: "API_KEY", value: "v2")

    scope = Secrets::Personal::Variable.for(account:, organization:).where(name: "API_KEY")
    expect(scope.count).to eq(1)
    expect(scope.first.value).to eq("v2")
  end

  it "crea uno snapshot SOLO se il plaintext cambia" do
    first = described_class.call(account:, organization:, name: "API_KEY", value: "v1").value
    expect(first.versions.count).to eq(1)

    described_class.call(account:, organization:, name: "API_KEY", value: "v1") # stesso valore
    expect(first.reload.versions.count).to eq(1)

    described_class.call(account:, organization:, name: "API_KEY", value: "v2") # valore nuovo
    expect(first.reload.versions.count).to eq(2)
  end

  it "non salta audit di default ma lo omette con audit: false" do
    expect { described_class.call(account:, organization:, name: "A", value: "1", audit: false) }
      .not_to change(Secrets::Personal::Event, :count)
  end

  it "ritorna R422-PERSONALSECRET-001 su nome invalido" do
    result = described_class.call(account:, organization:, name: "1BAD", value: "x")

    expect(result).to be_err
    expect(result.error.code).to eq("R422-PERSONALSECRET-001")
  end
end
