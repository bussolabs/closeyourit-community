# frozen_string_literal: true

require "rails_helper"

# CYRA-1070 — a cancelled run never came back: the workflow is born with the ticket and nothing made a
# second one, so the ticket stayed out of the automation for good.
RSpec.describe Agents::Workflows::Restart do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:owner) { create(:account) }

  before do
    create(:membership, :owner, organization:, account: owner)
    workflow.update!(triage_started_at: 2.hours.ago, triaged_at: 2.hours.ago, planned_at: 1.hour.ago,
                     cancelled_at: 10.minutes.ago, cancelled_by: owner, cancellation_reason: "Start over")
  end

  it "replaces the cancelled run with a new one that starts from triage" do
    result = described_class.call(workflow:, actor: owner)

    expect(result).to be_ok
    fresh = ticket.reload.agent_workflow
    expect(fresh.id).not_to eq(workflow.id)
    expect(fresh).to have_attributes(cancelled_at: nil, planned_at: nil, triage_requested_at: be_present)
    expect(fresh.ready_execution_phase).to eq("triage")
  end

  it "refuses a run that is not cancelled" do
    workflow.update!(cancelled_at: nil)

    expect(described_class.call(workflow:, actor: owner)).to be_err
    expect(ticket.reload.agent_workflow.id).to eq(workflow.id)
  end

  it "refuses a member without the admin or owner role" do
    member = create(:membership, organization:, role: :member).account

    expect(described_class.call(workflow:, actor: member)).to be_err
    expect(ticket.reload.agent_workflow.id).to eq(workflow.id)
  end

  it "refuses a concluded ticket" do
    ticket.update_columns(status_id: create(:ticket_status, :done, organization:).id)

    expect(described_class.call(workflow:, actor: owner)).to be_err
    expect(ticket.reload.agent_workflow.id).to eq(workflow.id)
  end
end
