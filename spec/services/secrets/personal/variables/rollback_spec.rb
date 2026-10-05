# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Personal::Variables::Rollback do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  it "ripristina il valore di una versione precedente creando una nuova versione" do
    variable = Secrets::Personal::Variables::Set.call(account:, organization:, name: "API_KEY", value: "v1").value
    Secrets::Personal::Variables::Set.call(account:, organization:, name: "API_KEY", value: "v2")
    v1 = variable.versions.find_by(number: 1)

    result = described_class.call(variable: variable.reload, version: v1)

    expect(result).to be_ok
    expect(variable.reload.value).to eq("v1")
    expect(variable.versions.count).to eq(3) # v1, v2, e il rollback
  end

  it "rifiuta il rollback a una versione di un altro secret → R422-PERSONALSECRET-003" do
    mine = Secrets::Personal::Variables::Set.call(account:, organization:, name: "MINE", value: "v1").value
    other = create(:personal_secret_variable)
    foreign_version = create(:personal_secret_version, variable: other)

    result = described_class.call(variable: mine, version: foreign_version)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-PERSONALSECRET-003")
  end
end
