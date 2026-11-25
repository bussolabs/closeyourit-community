# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::PruneNotificationsJob do
  it "handles an empty archive" do
    expect { described_class.perform_now }.not_to change(Alerting::Notification, :count)
  end

  it "deletes all expired batches with tied timestamps and preserves recent rows" do
    travel_to(Time.utc(2026, 6, 1, 12)) do
      template = create(:alerting_notification, created_at: 30.days.ago)
      attributes = template.attributes.except("id", "dedup_key")
      Alerting::Notification.insert_all!(Array.new(2_000) { |i| attributes.merge("dedup_key" => "batch-#{i}") })
      fresh = create(:alerting_notification, created_at: 30.days.ago + 1.second)

      described_class.perform_now

      expect(Alerting::Notification.pluck(:id)).to eq([ fresh.id ])
    end
  end

  it "bounds every selection and deletion in a mostly recent archive" do
    template = create(:alerting_notification, created_at: 1.day.ago)
    attributes = template.attributes.except("id", "dedup_key")
    Alerting::Notification.insert_all!(Array.new(100_000) { |i| attributes.merge("dedup_key" => "recent-#{i}") })
    Alerting::Notification.insert_all!(Array.new(2_000) do |i|
      attributes.merge("dedup_key" => "expired-#{i}", "created_at" => 31.days.ago)
    end)
    ActiveRecord::Base.connection.execute("ANALYZE alerting_notifications")

    expect_bounded_pruning(pruning_plans("alerting_notifications") { described_class.perform_now })
  end

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
