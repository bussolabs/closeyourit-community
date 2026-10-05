# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::ImpersonationEvent, type: :model do
  it "produce un evento valido" do
    expect(build(:impersonation_event)).to be_valid
  end

  it "collega god e account" do
    event = create(:impersonation_event)
    expect(event.god).to be_god
    expect(event.account).to be_a(Accounts::Account)
  end

  it "close! imposta ended_at e lo esclude dallo scope open" do
    event = create(:impersonation_event)
    expect(described_class.open).to include(event)
    event.close!
    expect(event.ended_at).to be_present
    expect(described_class.open).not_to include(event)
  end
end
