# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::BudgetRestart do
  let(:organization) { create(:organization) }
  let(:workflow) { create(:agent_workflow, organization:) }
  let(:host) do
    create(:agent_host, organization:, runtimes: [ { "name" => "claude", "present" => true },
                                                   { "name" => "codex", "present" => true } ])
  end

  it "returns nothing on a run that never started over" do
    expect(described_class.choice_for(workflow:, host:)).to be_nil
  end

  it "works on the engine written on the run, reviewed by the other one" do
    workflow.update!(budget_restart_engine: "codex")

    expect(described_class.choice_for(workflow:, host:).to_h)
      .to eq(engine: "codex", model: nil, reviewer: "claude")
  end

  # The machine keeps its usual engine: the restart still happened once, because what counts the runs
  # is the column being written.
  it "returns nothing when the machine lacks that engine" do
    workflow.update!(budget_restart_engine: "codex")
    host.update!(runtimes: [ { "name" => "claude", "present" => true } ])

    expect(described_class.choice_for(workflow:, host:)).to be_nil
  end

  # CYRA-1358
  it "returns nothing while the machine reports that engine out of quota" do
    workflow.update!(budget_restart_engine: "codex")
    host.update!(agent_quota: [ { "runtime" => "codex", "paused_until" => 2.hours.from_now.iso8601 } ])

    expect(described_class.choice_for(workflow:, host:)).to be_nil
  end

  # CYRA-1360 — the other engine cannot answer: the review goes to the reviewer the machine is set to use.
  it "is reviewed by the machine's own reviewer while the other engine is out of quota" do
    workflow.update!(budget_restart_engine: "claude")
    host.update!(work_engine: "claude", reviewer: "claude", supporter: "claude",
                 agent_quota: [ { "runtime" => "codex", "paused_until" => 2.hours.from_now.iso8601 } ])

    expect(described_class.choice_for(workflow:, host:).to_h)
      .to eq(engine: "claude", model: nil, reviewer: "claude")
  end

  it "returns nothing for an engine that cannot do the work" do
    workflow.update!(budget_restart_engine: "opencode")

    expect(described_class.choice_for(workflow:, host:)).to be_nil
  end
end
