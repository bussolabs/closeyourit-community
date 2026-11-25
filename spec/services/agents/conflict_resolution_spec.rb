# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::ConflictResolution do
  let(:organization) { create(:organization) }
  let(:workflow) { create(:agent_workflow, organization:, conflict_resolution_requested_at: Time.current) }
  let(:host) do
    create(:agent_host, organization:, runtimes: [ { "name" => "claude", "present" => true },
                                                   { "name" => "codex", "present" => true } ])
  end

  it "runs the round on Codex, reviewed by Claude" do
    expect(described_class.choice_for(workflow:, host:, phase: "autopilot").to_h)
      .to eq(engine: "codex", model: nil, reviewer: "claude")
  end

  it "leaves the other phases alone" do
    expect(described_class.choice_for(workflow:, host:, phase: "planner")).to be_nil
  end

  # CYRA-1361 — the machine's usual engine resolves the conflict instead of failing on the quota.
  it "returns nothing while the machine reports Codex out of quota" do
    host.update!(agent_quota: [ { "runtime" => "codex", "paused_until" => 2.hours.from_now.iso8601 } ])

    expect(described_class.choice_for(workflow:, host:, phase: "autopilot")).to be_nil
  end
end
