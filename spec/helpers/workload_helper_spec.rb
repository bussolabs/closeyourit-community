# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkloadHelper, type: :helper do
  describe "#workload_due_state" do
    let(:now) { Time.zone.local(2026, 3, 10, 12) }

    it "is nil without a due date" do
      expect(helper.workload_due_state(build(:workload_action, due_at: nil), now: now)).to be_nil
    end

    it "is late once the due date has passed on an open action" do
      expect(helper.workload_due_state(build(:workload_action, due_at: now - 1.hour), now: now)).to eq(:late)
    end

    it "is soon within the reminder threshold" do
      expect(helper.workload_due_state(build(:workload_action, due_at: now + 2.hours), now: now)).to eq(:soon)
    end

    it "is on time further away" do
      expect(helper.workload_due_state(build(:workload_action, due_at: now + 5.days), now: now)).to eq(:on_time)
    end

    it "never alarms on a closed action" do
      action = build(:workload_action, status: :done, due_at: now - 3.days)
      expect(helper.workload_due_state(action, now: now)).to eq(:on_time)
    end
  end
end
