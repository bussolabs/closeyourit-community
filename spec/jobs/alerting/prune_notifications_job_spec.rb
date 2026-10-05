# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::PruneNotificationsJob do
  it "gira sulla coda :batch dei lavori lunghi" do
    expect(described_class.new.queue_name).to eq("batch")
  end

  it "elimina le notifiche oltre 30 giorni e mantiene le recenti" do
    old = create(:alerting_notification, created_at: 31.days.ago)
    fresh = create(:alerting_notification, created_at: 1.day.ago)
    described_class.perform_now
    expect(::Alerting::Notification.exists?(old.id)).to be(false)
    expect(::Alerting::Notification.exists?(fresh.id)).to be(true)
  end

  it "confine: alla soglia (30 giorni esatti) viene eliminata, un secondo dopo la soglia resta" do
    travel_to(Time.utc(2026, 6, 1, 12)) do
      drop = create(:alerting_notification, created_at: 30.days.ago)            # == soglia → eliminata (<=)
      keep = create(:alerting_notification, created_at: 30.days.ago + 1.second) # più recente → resta
      described_class.perform_now
      expect(::Alerting::Notification.exists?(drop.id)).to be(false)
      expect(::Alerting::Notification.exists?(keep.id)).to be(true)
    end
  end
end
