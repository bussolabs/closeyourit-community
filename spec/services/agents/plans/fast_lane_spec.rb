# frozen_string_literal: true

require "rails_helper"

# CYRA-1300 — a small, low-risk piece of work does not wait for someone to approve its plan.
RSpec.describe Agents::Plans::FastLane do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, fast_lane: "on") }
  let(:ticket) { create(:ticket, organization:, project:, title: "Fix the label of the save button", with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow.tap { |flow| flow.update!(triaged_at: 2.minutes.ago, planned_at: 1.minute.ago) } }
  let(:attempt) { create(:agent_attempt, organization:, workflow:, phase: "planner") }
  let(:files) { [ "app/views/items/_form.html.erb", "config/locales/it.yml" ] }
  let(:plan) { build_plan(files) }

  def build_plan(paths, **attributes)
    items = [ { "id" => "WI-1", "title" => "Change the label", "description" => "One string.",
                "files" => paths.map { |path| { "path" => path, "line" => 1, "reason" => "The label lives here." } },
                "dependencies" => [] } ]
    Agents::Plan.create!(
      workflow:, attempt:, contract_version: 2, technical_analysis: "Change one label.", scenarios: [], notes: [],
      content: { "summary" => "Change one label.", "work_items" => items, "rationale" => [], "risks" => [],
                 "open_points" => [], "sources" => [] },
      definition_of_done: [ { "id" => "DOD-1", "text" => "The button reads Save" } ],
      ticket_snapshot_digest: "snapshot", **attributes
    )
  end

  def triage(risk: "low", requires_human_approval: false)
    create(:agent_attempt, organization:, workflow:, phase: "triage", status: :approved,
                           result: { "risk" => risk, "requires_human_approval" => requires_human_approval })
  end

  def events = Ticketing::Event.where(ticket:).where("action LIKE 'plan_fast_lane_%'")

  def reasons = events.sole.data["reasons"]

  it "approves a small low-risk plan with no person as approver, and says why in the ticket's history" do
    triage

    expect(described_class.call(workflow:, plan:)).to be(true)

    expect(workflow.reload).to have_attributes(approved_by_id: nil, frozen_plan_id: plan.id)
    expect(workflow.approved_at).to be_present
    expect(events.sole).to have_attributes(action: "plan_fast_lane_approved", actor_id: nil)
    expect(events.sole.data).to include("files" => 2, "plan_id" => plan.id)
  end

  it "does nothing and writes nothing while the project keeps it off" do
    project.update!(fast_lane: nil)
    triage

    expect(described_class.call(workflow:, plan:)).to be(false)
    expect(workflow.reload.approved_at).to be_nil
    expect(events).to be_empty
  end

  it "leaves the plan on the ordinary round in a dry run, and records that it would have passed" do
    project.update!(fast_lane: "dry_run")
    triage

    expect(described_class.call(workflow:, plan:)).to be(false)
    expect(workflow.reload.approved_at).to be_nil
    expect(events.sole).to have_attributes(action: "plan_fast_lane_would_approve")
  end

  it "does not count test files towards the limit" do
    triage
    plan = build_plan(files + [ "app/helpers/items_helper.rb", "spec/views/items/form_spec.rb", "test/items_test.rb" ])

    expect(described_class.call(workflow:, plan:)).to be(true)
  end

  {
    "the triage did not say low risk" => [ -> { triage(risk: "medium") }, nil, "triage_not_low" ],
    "the triage asked for a person" => [ -> { triage(requires_human_approval: true) }, nil, "triage_not_low" ],
    "no triage delivered a result" => [ -> { }, nil, "triage_not_low" ],
    "the plan names more than three files" => [ -> { triage }, %w[a.rb b.rb c.rb d.rb], "too_many_files" ],
    "the plan names no file" => [ -> { triage }, [], "no_files" ],
    "the plan touches the data structure" => [ -> { triage }, [ "db/migrate/20260101000000_add_x.rb" ], "sensitive_path" ],
    "the plan touches access code" => [ -> { triage }, [ "app/controllers/auth/sessions_controller.rb" ], "sensitive_path" ],
    "the plan touches the CI" => [ -> { triage }, [ ".github/workflows/ci.yml" ], "sensitive_path" ]
  }.each do |title, (given, paths, reason)|
    it "keeps the ordinary round when #{title}" do
      instance_exec(&given)
      candidate = paths ? build_plan(paths) : plan

      expect(described_class.call(workflow:, plan: candidate)).to be(false)
      expect(workflow.reload.approved_at).to be_nil
      expect(events).to be_empty
      expect(described_class.new(workflow:, plan: candidate).reasons).to include(reason)
    end
  end

  it "keeps the ordinary round on a reserved topic" do
    triage
    ticket.update!(title: "Change the billing label")

    expect(described_class.call(workflow:, plan:)).to be(false)
    expect(described_class.new(workflow:, plan:).reasons).to include("reserved_topic")
  end

  it "keeps the ordinary round when the plan proposes to skip the system's gates" do
    triage
    plan.update_columns(content: plan.content.merge("summary" => "Finish with git push --force origin main."))

    expect(described_class.call(workflow:, plan: plan.reload)).to be(false)
    expect(described_class.new(workflow:, plan:).reasons).to include("bypass_suspected")
  end

  it "keeps the ordinary round for a plan written before work items existed" do
    triage
    legacy = Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Change one label.", scenarios: [],
                                  definition_of_done: [ "The button reads Save" ], notes: [],
                                  ticket_snapshot_digest: "snapshot")

    expect(described_class.call(workflow:, plan: legacy)).to be(false)
  end

  it "leaves alone a plan someone already decided on" do
    triage
    plan.update_columns(change_request: "Use the other label.")

    expect(described_class.call(workflow:, plan: plan.reload)).to be(false)
    expect(workflow.reload.approved_at).to be_nil
  end
end
