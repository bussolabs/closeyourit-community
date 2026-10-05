# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Personal::Bundle do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  it "ritorna la mappa decifrata { name => value } ordinata per nome" do
    create(:personal_secret_variable, account:, organization:, name: "B_KEY", value: "b")
    create(:personal_secret_variable, account:, organization:, name: "A_KEY", value: "a")

    result = described_class.call(account:, organization:)

    expect(result).to be_ok
    expect(result.value).to eq({ "A_KEY" => "a", "B_KEY" => "b" })
  end

  it "non include i secret di un altro account/org" do
    create(:personal_secret_variable, account:, organization:, name: "MINE", value: "x")
    create(:personal_secret_variable, name: "OTHER", value: "y")

    expect(described_class.call(account:, organization:).value.keys).to eq([ "MINE" ])
  end

  it "bundle vuoto → {}" do
    expect(described_class.call(account:, organization:).value).to eq({})
  end
end
