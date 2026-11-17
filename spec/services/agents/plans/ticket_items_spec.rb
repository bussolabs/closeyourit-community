# frozen_string_literal: true

require "rails_helper"

# CYRA-1319 — a v3 plan proves the ticket's acceptance items; its proposals enter the ticket on approval.
RSpec.describe Agents::Plans::TicketItems do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) do
    create(:ticket, organization:, project:, with_agent_workflow: true, description: "Check the link.",
                    conditions_attributes: [ { text: "Templates inspected", position: 0 } ],
                    scenarios_attributes: [ { title: "Link present", step_given: "a client", step_when: "opens the page",
                                              step_expected: "sees the link", position: 1 } ])
  end
  let(:workflow) { ticket.agent_workflow }
  let(:cto) do
    create(:account).tap do |account|
      create(:membership, account:, organization:)
      create(:project_membership, account:, project:)
    end
  end
  let(:proof) { { "kind" => "test", "how" => "A request spec opens the page." } }

  before do
    organization.update!(cto:)
    workflow.update!(triaged_at: 2.minutes.ago, planned_at: Time.current)
  end

  def codes = ticket.acceptance_items.map(&:code)

  def v3_plan(verifications: codes.map { { "code" => it, "revision" => 1, "verification" => proof } }, proposed: [])
    result = { "item_verifications" => verifications, "proposed_items" => proposed }
    Agents::Plan.create!(
      workflow:, attempt: create(:agent_attempt, organization:, workflow:, phase: "planner"), contract_version: 3,
      technical_analysis: "Fix the link.", scenarios: [], notes: [], ticket_snapshot_digest: "snapshot",
      content: { "summary" => "Fix the link.", "work_items" => [] },
      definition_of_done: described_class.snapshot(ticket, result)
    )
  end

  it "records one entry per ticket item, with its code, revision, text and proof" do
    plan = v3_plan

    expect(plan.definition_of_done.map { it.slice("id", "revision", "text") })
      .to eq([ { "id" => codes.first, "revision" => 1, "text" => "Templates inspected" },
               { "id" => codes.last, "revision" => 1, "text" => "Link present" } ])
    expect(plan.definition_of_done.map { it["verification"] }).to all(eq(proof))
    expect(plan.needs_person_for_items?).to be(false)
  end

  it "leaves to a person a plan that proposes items or leaves one unproven" do
    expect(v3_plan(verifications: []).needs_person_for_items?).to be(true)
    proposed = [ { "ref" => "NEW-1", "format" => "text", "text" => "The link opens in the same tab", "verification" => proof } ]
    expect(v3_plan(proposed:).needs_person_for_items?).to be(true)
  end

  it "writes the proposals into the ticket on approval, with their real codes" do
    v3_plan(proposed: [ { "ref" => "NEW-1", "format" => "text", "text" => "The link opens in the same tab", "verification" => proof } ])

    expect(Agents::Workflows::ApprovePlan.call(workflow:, actor: cto)).to be_ok

    expect(ticket.reload.conditions.map(&:text)).to include("The link opens in the same tab")
    frozen = workflow.reload.frozen_plan.definition_of_done
    expect(frozen.map { it["id"] }).to eq(codes.first(2) + [ "AC-3" ])
    expect(frozen.last).to include("added" => true, "verification" => proof)
    expect(frozen.last).not_to have_key("proposed")
  end

  it "refuses the approval when an item changed after the plan read it" do
    v3_plan
    ticket.conditions.first.update!(text: "Templates inspected and fixed")

    result = Agents::Workflows::ApprovePlan.call(workflow:, actor: cto)

    expect(result.error.code).to eq("R409-WORKFLOW-019")
    expect(workflow.reload.approved_at).to be_nil
  end

  it "refuses the approval when an item was added after the plan" do
    v3_plan
    ticket.conditions.create!(text: "A new requirement", position: 5)

    expect(Agents::Workflows::ApprovePlan.call(workflow:, actor: cto).error.code).to eq("R409-WORKFLOW-019")
  end

  context "with the council on" do
    before do
      create(:agent_automator_setting, organization:, council_mode: "on")
      create(:agent_council_proposal, ticket:, outcome: "ticket")
    end

    it "approves on its own a plan that proves every item and proposes none" do
      v3_plan

      Agents::Workflows::CouncilApprovePlan.call(workflow:)

      expect(workflow.reload.approved_at).to be_present
    end

    it "leaves to a person a plan that proposes items" do
      v3_plan(proposed: [ { "ref" => "NEW-1", "format" => "text", "text" => "Extra", "verification" => proof } ])

      Agents::Workflows::CouncilApprovePlan.call(workflow:)

      expect(workflow.reload.approved_at).to be_nil
    end
  end

  describe "an item changed after the approval" do
    before do
      v3_plan
      Agents::Workflows::ApprovePlan.call(workflow:, actor: cto)
    end

    def update(extra)
      params = { title: ticket.title, status_id: ticket.status_id, priority_id: ticket.priority_id }.merge(extra)
      Ticketing::UpdateTicket.call(organization:, ticket: ticket.reload, actor: cto, channel: :web, params:)
    end

    def edit_first_condition(text)
      update(conditions_attributes: [ { id: ticket.conditions.first.id, text: } ])
    end

    it "sends the ticket back to planning before the work starts, and says why" do
      expect(edit_first_condition("Templates inspected and listed")).to be_ok

      expect(workflow.reload).to have_attributes(approved_at: nil, planned_at: nil)
      expect(Ticketing::Event.where(ticket:, action: "plan_reopened_items_changed")).to exist
    end

    it "leaves the plan alone when the items did not change" do
      expect(update(title: "A new title")).to be_ok

      expect(workflow.reload.approved_at).to be_present
    end
  end
end
