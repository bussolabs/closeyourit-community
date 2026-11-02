# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Workflows::CouncilApprovePlan do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow.tap { |w| w.update!(triaged_at: 2.minutes.ago, planned_at: 1.minute.ago) } }
  let(:attempt) { create(:agent_attempt, organization:, workflow:) }
  let!(:plan) do
    Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Plan", scenarios: [],
                         definition_of_done: [ "RSpec" ], notes: [], ticket_snapshot_digest: "snapshot")
  end

  before { create(:agent_automator_setting, organization:, council_mode: "on") }

  it "approves the plan of a council ticket with no person as approver" do
    create(:agent_council_proposal, ticket:, outcome: "ticket")
    expect(described_class.call(workflow:)).to be_ok
    expect(workflow.reload).to have_attributes(approved_by_id: nil, frozen_plan_id: plan.id)
    expect(workflow.approved_at).to be_present
  end

  it "leaves the plan of any other ticket to the CTO" do
    described_class.call(workflow:)
    expect(workflow.reload.approved_at).to be_nil
  end

  it "leaves the plan to the CTO when the council is not on" do
    organization.automator_setting.update!(council_mode: "dry_run")
    create(:agent_council_proposal, ticket:, outcome: "ticket")
    described_class.call(workflow:)
    expect(workflow.reload.approved_at).to be_nil
  end

  it "records the approval in the ticket history, with no person as actor" do
    create(:agent_council_proposal, ticket:, outcome: "ticket")
    expect { described_class.call(workflow:) }
      .to change { Ticketing::Event.where(ticket:, action: "plan_council_approved").count }.by(1)
    expect(Ticketing::Event.find_by(ticket:, action: "plan_council_approved").actor).to be_nil
  end

  it "does nothing on a concluded ticket" do
    create(:agent_council_proposal, ticket:, outcome: "ticket")
    ticket.update!(status: create(:ticket_status, :done, organization:))
    expect(described_class.call(workflow:).value).to be_nil
    expect(workflow.reload.approved_at).to be_nil
    expect(Ticketing::Event.where(action: "plan_council_approved")).to be_empty
  end

  it "does nothing when the plan is already approved" do
    create(:agent_council_proposal, ticket:, outcome: "ticket")
    plan.update!(approved_at: Time.current)
    expect(described_class.call(workflow:).value).to be_nil
    expect(workflow.reload.approved_at).to be_nil
  end

  it "does nothing when the plan has a change request" do
    create(:agent_council_proposal, ticket:, outcome: "ticket")
    plan.update!(change_request: "Rework the scope")
    expect(described_class.call(workflow:).value).to be_nil
    expect(workflow.reload.approved_at).to be_nil
  end

  it "does nothing when the council is off" do
    organization.automator_setting.update!(council_mode: "off")
    create(:agent_council_proposal, ticket:, outcome: "ticket")
    described_class.call(workflow:)
    expect(workflow.reload.approved_at).to be_nil
  end
end
