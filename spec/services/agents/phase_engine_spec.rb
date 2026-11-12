# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::PhaseEngine do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:host) do
    create(:agent_host, organization:, runtimes: [ { "name" => "claude", "present" => true },
                                                  { "name" => "codex", "present" => true } ])
  end

  it "returns nothing when the project made no choice" do
    expect(described_class.choice_for(phase: "triage", project:, host:)).to be_nil
  end

  it "returns the chosen engine and model for a light phase, with the other engine as reviewer" do
    project.update!(light_phase_engine: "claude:claude-sonnet-5-5")

    %w[triage closer_staging closer_production].each do |phase|
      expect(described_class.choice_for(phase:, project:, host:).to_h)
        .to eq(engine: "claude", model: "claude-sonnet-5-5", reviewer: "codex")
    end
  end

  it "leaves the plan and the code on the machine's engine" do
    project.update!(light_phase_engine: "claude:claude-sonnet-5-5")

    %w[planner autopilot].each do |phase|
      expect(described_class.choice_for(phase:, project:, host:)).to be_nil
    end
  end

  it "returns nothing when the machine lacks the engine" do
    project.update!(light_phase_engine: "codex:gpt-6-astra")
    host.update!(runtimes: [ { "name" => "claude", "present" => true } ])

    expect(described_class.choice_for(phase: "triage", project:, host:)).to be_nil
  end

  it "refuses an engine or a model outside the allowed ones" do
    project.light_phase_engine = "claude:some-other-model"
    expect(project).not_to be_valid

    project.light_phase_engine = "opencode:anything"
    expect(project).not_to be_valid

    project.light_phase_engine = ""
    expect(project).to be_valid
    expect(project.light_phase_engine).to be_nil
  end
end
