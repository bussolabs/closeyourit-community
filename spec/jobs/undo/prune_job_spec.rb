# frozen_string_literal: true

require "rails_helper"

RSpec.describe Undo::PruneJob, type: :job do
  it "deletes the expired entries and keeps the live ones" do
    organization = create(:organization)
    account = create(:account)
    expired = Undo::Entry.create!(kind: "notifications", organization:, account:, items: [], expires_at: 1.minute.ago)
    live = Undo::Entry.create!(kind: "notifications", organization:, account:, items: [], expires_at: 10.seconds.from_now)

    described_class.perform_now

    expect(Undo::Entry.exists?(expired.id)).to be(false)
    expect(Undo::Entry.exists?(live.id)).to be(true)
  end
end
