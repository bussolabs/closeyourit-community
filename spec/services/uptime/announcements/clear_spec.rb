# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::Announcements::Clear do
  it "rimuove il banner del monitor" do
    monitor = create(:uptime_monitor)
    create(:uptime_announcement, monitor:)

    expect { described_class.call(monitor:) }.to change(Uptime::Announcement, :count).by(-1)
    expect(monitor.reload.announcement).to be_nil
  end

  it "idempotente senza banner (no-op)" do
    monitor = create(:uptime_monitor)
    expect(described_class.call(monitor:)).to be_ok
  end
end
