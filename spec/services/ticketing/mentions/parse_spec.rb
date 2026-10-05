# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::Mentions::Parse do
  let(:org) { create(:organization) }
  let(:other_org) { create(:organization) }

  def member(handle, organization: org)
    create(:account, handle: handle).tap do |account|
      create(:membership, account: account, organization: organization, role: :member)
    end
  end

  it "risolve gli handle dei membri dell'org" do
    a = member("mario")
    b = member("luigi")
    expect(described_class.call(text: "ping @mario e @luigi", organization: org)).to contain_exactly(a, b)
  end

  it "scarta gli handle sconosciuti" do
    expect(described_class.call(text: "ciao @nessuno", organization: org)).to be_empty
  end

  it "scarta i membri di un'ALTRA org (anti-leak)" do
    member("ext", organization: other_org)
    expect(described_class.call(text: "@ext", organization: org)).to be_empty
  end

  it "è case-insensitive" do
    a = member("mario")
    expect(described_class.call(text: "@Mario", organization: org)).to contain_exactly(a)
  end

  it "deduplica le menzioni ripetute" do
    a = member("mario")
    expect(described_class.call(text: "@mario @mario @mario", organization: org)).to contain_exactly(a)
  end

  it "ignora gli indirizzi email (non sono menzioni)" do
    member("example")
    expect(described_class.call(text: "scrivimi a foo@example.com", organization: org)).to be_empty
  end

  it "ritorna [] su testo vuoto" do
    expect(described_class.call(text: "", organization: org)).to eq([])
  end
end
