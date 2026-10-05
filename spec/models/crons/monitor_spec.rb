# frozen_string_literal: true

require "rails_helper"

RSpec.describe Crons::Monitor, type: :model do
  let(:project) { create(:project) }

  describe "validazioni" do
    it { expect(build(:cron_monitor)).to be_valid }

    it "slug unico per progetto" do
      create(:cron_monitor, project:, slug: "nightly")
      expect(build(:cron_monitor, project:, slug: "nightly")).not_to be_valid
      expect(build(:cron_monitor, slug: "nightly")).to be_valid # altro progetto
    end

    it "expected_interval_minutes deve essere > 0" do
      expect(build(:cron_monitor, expected_interval_minutes: 0)).not_to be_valid
    end
  end

  describe "#overdue?" do
    it "mai fatto check-in → scaduto (atteso ma assente)" do
      monitor = build(:cron_monitor, last_check_in_at: nil)
      expect(monitor.overdue?).to be(true)
    end

    it "confine: check-in a intervallo+grazia -1s → non scaduto; +1s → scaduto" do
      monitor = build(:cron_monitor, expected_interval_minutes: 60, grace_minutes: 5)
      now = Time.utc(2026, 7, 2, 12)
      window = 65.minutes
      monitor.last_check_in_at = now - window + 1.second
      expect(monitor.overdue?(now)).to be(false)
      monitor.last_check_in_at = now - window - 1.second
      expect(monitor.overdue?(now)).to be(true)
    end

    it "disabilitato → mai scaduto" do
      monitor = build(:cron_monitor, enabled: false, last_check_in_at: nil)
      expect(monitor.overdue?).to be(false)
    end
  end
end
