# frozen_string_literal: true

require "rails_helper"

# CYRA-1152 — approving an epic's split creates its children and their prerequisites, all or none, in the
# name of whoever approved; the epic's run ends instead of moving on to writing code.
RSpec.describe Agents::Workflows::SplitEpic do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:epic) { create(:ticket, :epic, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { epic.agent_workflow }
  let(:cto) do
    create(:account).tap do |account|
      create(:membership, account:, organization:)
      create(:project_membership, account:, project:)
    end
  end
  let(:attempt) { create(:agent_attempt, organization:, workflow:, phase: "planner") }

  def child(id, dependencies = [])
    { "id" => id, "title" => "Child #{id}", "description" => "Work of #{id}.", "dependencies" => dependencies,
      "scenarios" => [ { "id" => "SC-1", "title" => "Works", "given" => "a user", "when" => "they act",
                         "then" => "it happens", "expected" => "they see it" } ] }
  end

  let!(:plan) do
    Agents::Plan.create!(workflow:, attempt:, contract_version: 2, technical_analysis: "Split", scenarios: [],
                         definition_of_done: [ "RSpec" ], notes: [], ticket_snapshot_digest: "snapshot",
                         content: { "summary" => "Split the epic",
                                    "children" => [ child("CH-1"), child("CH-2"), child("CH-3", %w[CH-1 CH-2]) ] })
  end

  before do
    organization.update!(cto:)
    workflow.update!(triaged_at: 2.minutes.ago, planned_at: Time.current)
  end

  def approve(actor = cto) = Agents::Workflows::ApprovePlan.call(workflow:, actor:)

  def child_named(id) = epic.children.find_by!(title: "Child #{id}")

  it "creates the children under the epic, in the approver's name, with their prerequisites" do
    expect { expect(approve).to be_ok }.to change { epic.children.count }.from(0).to(3)

    epic.children.each do |created|
      expect(created).to have_attributes(reporter: cto, kind: "story", priority_id: epic.priority_id)
      expect(created.scenarios.sole).to have_attributes(step_given: "a user", step_expected: "they see it")
      expect(created.agent_workflow.triage_requested_at).to be_present
    end
    last = child_named("CH-3")
    expect(last.blockers).to contain_exactly(child_named("CH-1"), child_named("CH-2"))
    expect(last.dependencies.map(&:created_by)).to all(eq(cto))
    expect(child_named("CH-1").blockers).to be_empty
    expect(Ticketing::Event.where(ticket: last, action: "dependency_added", actor: cto).count).to eq(2)
  end

  it "ends the epic's run instead of moving on to writing code" do
    expect(approve).to be_ok

    expect(plan.reload).to have_attributes(approved_by: cto, approved_at: be_present)
    expect(workflow.reload.phase).to eq("completed")
    expect(workflow.ready_execution_phase).to be_nil
  end

  it "creates each child with the whole description the person approved, even right at the limit" do
    description = ("x" * (Ticketing::Constants::DESCRIPTION_MAX_CHARS - 6)) + " Fine."
    plan.update!(content: plan.content.merge("children" => [ child("CH-1").merge("description" => description), child("CH-2") ]))

    expect(approve).to be_ok

    expect(child_named("CH-1").description).to eq(description)
  end

  it "creates nothing when one child cannot be created" do
    allow(Ticketing::CreateTicket).to receive(:call).and_wrap_original do |original, **arguments|
      next original.call(**arguments) unless arguments.dig(:params, :title) == "Child CH-3"

      Result.err(AppError.new("Not valid", code: "R422-TICKET-001"))
    end

    expect { expect(approve).to be_err }.not_to change(Ticketing::Ticket, :count)
    expect(Connections::TicketDependency.count).to eq(0)
    expect(plan.reload.approved_at).to be_nil
    expect(workflow.reload.completed_at).to be_nil
  end

  it "creates nothing when the ticket is no longer an epic" do
    epic.update!(kind: :story)

    result = approve

    expect(result.error.code).to eq("R409-WORKFLOW-018")
    expect(Ticketing::Ticket.where(parent_id: epic.id)).to be_empty
    expect(plan.reload.approved_at).to be_nil
  end

  it "denies the approval to someone who is not responsible for the project, and creates nothing" do
    other = create(:account).tap do |account|
      create(:membership, account:, organization:)
      create(:project_membership, account:, project:)
    end

    expect { expect(approve(other).error.code).to eq("R403-WORKFLOW-001") }.not_to change(Ticketing::Ticket, :count)
    expect(plan.reload.approved_at).to be_nil
  end

  it "sends a rejected proposal back to the planner with its reason, and creates nothing" do
    expect do
      expect(Agents::Workflows::RequestPlanChanges.call(workflow:, actor: cto, reason: "Too fine: merge 1 and 2")).to be_ok
    end.not_to change(Ticketing::Ticket, :count)

    expect(plan.reload.change_request).to eq("Too fine: merge 1 and 2")
    expect(workflow.reload.ready_execution_phase).to eq("planner")
  end

  it "rejects from the approvals queue too without creating anything" do
    visible = Authorization::VisibleScope.new(account: cto, organization:)
    decide = Home::Approvals::Decide.call(account: cto, organization:, visible_projects: visible.projects,
                                          visible_tickets: visible.tickets, key: "agent_plan:#{workflow.id}",
                                          decision: "reject", text: "Split it differently")

    expect(decide).to be_ok
    expect(epic.children).to be_empty
    expect(plan.reload.change_request).to eq("Split it differently")
  end
end
