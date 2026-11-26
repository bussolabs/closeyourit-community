# frozen_string_literal: true

require "rails_helper"

# CYRA-1154 — the push enqueues the job right away; the recurring round reads again the due rows.
RSpec.describe Agents::ConflictCheckJob do
  let(:organization) { create(:organization) }

  it "runs only the rows that are due, oldest first" do
    due = create(:agent_conflict_check, organization:, next_check_at: 1.minute.ago)
    later = create(:agent_conflict_check, organization:, next_check_at: 1.minute.from_now)
    allow(Agents::ConflictChecks::Run).to receive(:call)

    described_class.perform_now

    expect(Agents::ConflictChecks::Run).to have_received(:call).with(check: due).once
    expect(Agents::ConflictChecks::Run).not_to have_received(:call).with(check: later)
  end

  it "leaves the rows past the cap due for the next round, which takes them" do
    stub_const("#{described_class}::BATCH", 1)
    first = create(:agent_conflict_check, organization:, next_check_at: 2.minutes.ago)
    second = create(:agent_conflict_check, organization:, next_check_at: 1.minute.ago)
    allow(Agents::ConflictChecks::Run).to receive(:call) { |check:| check.update!(state: :clean, next_check_at: nil) }

    described_class.perform_now
    expect(Agents::ConflictChecks::Run).to have_received(:call).with(check: first).once
    expect(second.reload).to be_state_pending

    described_class.perform_now
    expect(Agents::ConflictChecks::Run).to have_received(:call).with(check: second).once
  end

  it "keeps going when one row fails" do
    first = create(:agent_conflict_check, organization:, next_check_at: 2.minutes.ago)
    second = create(:agent_conflict_check, organization:, next_check_at: 1.minute.ago)
    allow(Agents::ConflictChecks::Run).to receive(:call).with(check: first).and_raise(StandardError, "boom")
    allow(Agents::ConflictChecks::Run).to receive(:call).with(check: second)

    expect { described_class.perform_now }.not_to raise_error
    expect(Agents::ConflictChecks::Run).to have_received(:call).with(check: second)
  end

  it "is scheduled every minute on the maintenance lane" do
    schedule = YAML.safe_load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true)
    task = schedule.fetch("production").fetch("check_agent_merge_conflicts")

    expect(task).to include("class" => "Agents::ConflictCheckJob", "queue" => "maintenance", "schedule" => "every minute")
  end
end
