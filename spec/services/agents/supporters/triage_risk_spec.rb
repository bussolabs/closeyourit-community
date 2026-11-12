# frozen_string_literal: true

require "rails_helper"

# CYRA-1293 — what the triage said about the ticket becomes the floor under every later score.
RSpec.describe Agents::Supporters::TriageRisk do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }

  def triage!(result, created_at: Time.current)
    create(:agent_attempt, organization:, workflow:, phase: "triage", result:, created_at:)
  end

  def reading = described_class.for(workflow)

  context "when the project keeps the rule off" do
    it "reads nothing" do
      triage!({ "risk" => "high", "state" => "workable" })

      expect(reading).to have_attributes(floor: nil, applied: nil, stops?: false, evidence: {})
    end
  end

  context "when the project switched the rule on" do
    before { project.update!(triage_risk_floor: "on") }

    it "puts a high-risk ticket past the autonomous range" do
      triage!({ "risk" => "high", "state" => "workable" })

      expect(reading).to have_attributes(floor: 9, applied: 9, stops?: true)
    end

    it "treats a triage that asks for a person as high risk" do
      triage!({ "risk" => "low", "requires_human_approval" => true })

      expect(reading.applied).to eq(9)
    end

    it "raises a medium-risk ticket without stopping it" do
      triage!({ "risk" => "medium" })

      expect(reading).to have_attributes(applied: 4, stops?: false)
    end

    it "sets no floor on a low-risk ticket" do
      triage!({ "risk" => "low" })

      expect(reading).to have_attributes(floor: nil, applied: nil)
    end

    it "reads the newest triage that delivered a result" do
      triage!({ "risk" => "high" }, created_at: 2.hours.ago)
      triage!({ "risk" => "low" }, created_at: 1.hour.ago)
      triage!({}, created_at: 1.minute.ago)

      expect(reading.floor).to be_nil
    end

    it "sets no floor when the ticket was never triaged" do
      expect(reading.floor).to be_nil
    end
  end

  context "when the project runs the rule as a dry run" do
    before { project.update!(triage_risk_floor: "dry_run") }

    it "reads the floor without applying it" do
      triage!({ "risk" => "high" })

      expect(reading).to have_attributes(floor: 9, applied: nil, stops?: false,
                                         evidence: { "triage_floor" => 9, "triage_floor_mode" => "dry_run" })
    end
  end
end
