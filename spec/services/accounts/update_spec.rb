# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::Update do
  it "updates display fields while keeping the recovery email unchanged" do
    account = create(:account, name: "Old Name", email: "old@example.com")
    result = described_class.call(
      account: account,
      attributes: { name: "New Name", handle: "new_handle" }
    )

    expect(result).to be_ok
    account.reload
    expect(account.name).to eq("New Name")
    expect(account.email).to eq("old@example.com")
    expect(account.handle).to eq("new_handle")
  end

  it "normalizes the handle and accepts an unchanged email" do
    account = create(:account, email: "mixed@example.com")
    result = described_class.call(
      account: account,
      attributes: { name: "X", email: "  MixED@Example.COM ", handle: "MyHandle" }
    )

    expect(result).to be_ok
    account.reload
    expect(account.email).to eq("mixed@example.com")
    expect(account.handle).to eq("myhandle")
  end

  it "nome vuoto → Result.err R422-ACCOUNTS-001 con details" do
    account = create(:account, name: "Keep")
    result = described_class.call(account: account, attributes: { name: "  " })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-ACCOUNT-001")
    expect(result.error.details[:name]).to be_present
    expect(account.reload.name).to eq("Keep")
  end

  it "email duplicata → Result.err con details su email" do
    create(:account, email: "taken@example.com")
    account = create(:account, email: "mine@example.com")
    result = described_class.call(account: account, attributes: { email: "taken@example.com" })

    expect(result).to be_err
    expect(result.error.details[:email]).to be_present
    expect(account.reload.email).to eq("mine@example.com")
  end

  it "handle di formato invalido → Result.err con details su handle" do
    account = create(:account)
    result = described_class.call(account: account, attributes: { handle: "Bad Handle!" })

    expect(result).to be_err
    expect(result.error.details[:handle]).to be_present
  end
end
