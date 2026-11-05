# frozen_string_literal: true

require "rails_helper"

# CYRA-1193 — the supporter judges a plan, the server decides whether it is approved without a person.
RSpec.describe Agents::Supporters::JudgePlan do
  let(:organization) { create(:organization) }
  let(:service_account) do
    create(:account, :service).tap { |a| create(:membership, account: a, organization:, role: :member) }
  end
  let(:host) { create(:agent_host, organization:, service_account:) }
  let(:project) { create(:project, organization:, supporter_enabled: true) }
  let(:ticket) { create(:ticket, organization:, project:, title: "Sort the list by name", with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow.tap { |w| w.update!(triaged_at: 2.minutes.ago, planned_at: 1.minute.ago) } }
  let(:attempt) { create(:agent_attempt, organization:, workflow:) }
  let!(:plan) do
    Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Sort the list in the index view.", scenarios: [],
                         definition_of_done: [ "The list is sorted" ], notes: [], ticket_snapshot_digest: "snapshot")
  end

  def verdict(**overrides)
    { recommendation: "approve", risk_score: 3, confidence: "high", touched_paths: [ "app/views/items/index.html.erb" ],
      sources: [ "README.md" ], rationale: "r", reasons_against: "a", assumptions: "s", undo: "u" }.merge(overrides)
  end

  def judge(digest: Agents::Supporters::NextPlan.digest(plan), **overrides)
    described_class.call(host:, plan_id: plan.id, payload: { digest:, verdict: verdict(**overrides) })
  end

  it "approves a low-risk plan with no person as approver and records the decision" do
    result = judge

    expect(result.value[:outcome]).to eq("approved")
    expect(workflow.reload).to have_attributes(approved_by_id: nil, frozen_plan_id: plan.id)
    expect(workflow.approved_at).to be_present
    expect(Agents::SupporterDecision.find_by!(target_type: "plan", target_id: plan.id))
      .to have_attributes(outcome: "approved", risk_score: 3, engine: host.effective_supporter)
    expect(Ticketing::Event.where(ticket:, action: "plan_supporter_approved").count).to eq(1)
  end

  it "leaves the plan to a person when the supporter escalates" do
    expect(judge(recommendation: "escalate").value).to include(outcome: "escalated", reasons: [ "supporter_escalated" ])
    expect(workflow.reload.approved_at).to be_nil
  end

  it "raises the score on database paths and leaves the plan to a person" do
    result = judge(touched_paths: [ "db/migrate/20261104000000_add_rank.rb" ])

    expect(result.value).to include(outcome: "escalated", risk_score: 8)
    expect(result.value[:reasons]).to include("risk_above_threshold")
    expect(workflow.reload.approved_at).to be_nil
  end

  it "leaves the plan to a person when it hits a reserved topic" do
    ticket.update!(title: "Change the invoice totals")

    expect(judge.value[:reasons]).to include("reserved_topic")
    expect(workflow.reload.approved_at).to be_nil
  end

  it "leaves the plan to a person on low confidence" do
    expect(judge(confidence: "low").value[:reasons]).to eq([ "low_confidence" ])
  end

  it "refuses a verdict on a version it did not read" do
    result = judge(digest: "sha256:old")

    expect(result.error.code).to eq("R409-SUPPORTER-004")
    expect(Agents::SupporterDecision.count).to eq(0)
  end

  it "answers a repeated verdict with the decision already taken" do
    judge
    expect(judge(recommendation: "escalate").value[:outcome]).to eq("approved")
    expect(Agents::SupporterDecision.count).to eq(1)
  end

  it "refuses when the supporter is off on the project" do
    project.update!(supporter_enabled: false)

    expect(judge.error.code).to eq("R403-SUPPORTER-001")
  end

  it "does not reach a plan of another organization" do
    other = create(:agent_host, organization: create(:organization))
    result = described_class.call(host: other, plan_id: plan.id, payload: { digest: "x", verdict: verdict })

    expect(result.error.code).to eq("R404-SUPPORTER-004")
  end
end
