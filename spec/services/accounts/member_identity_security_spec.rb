# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::Update do
  let(:account) { create(:account, name: "Original", email: "original@example.com") }

  it "rejects a recovery email change atomically" do
    result = described_class.call(account:, attributes: { email: "attacker@example.com", name: "Changed" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-ACCOUNT-001")
    expect(result.error.details[:email]).to be_present
    expect(account.reload).to have_attributes(name: "Original", email: "original@example.com")
  end

  it "rejects clearing the recovery email through string keys" do
    result = described_class.call(account:, attributes: { "email" => nil })

    expect(result).to be_err
    expect(account.reload.email).to eq("original@example.com")
  end

  it "accepts an unchanged normalized email from existing clients" do
    result = described_class.call(account:, attributes: { "email" => " ORIGINAL@example.com ", "name" => "Updated" })

    expect(result).to be_ok
    expect(account.reload).to have_attributes(name: "Updated", email: "original@example.com")
  end
end
