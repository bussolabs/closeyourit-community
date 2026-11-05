# frozen_string_literal: true

require "rails_helper"

# CYRA-1197 — another agent looks at a stopped workflow before a person is called; the server decides.
RSpec.describe Agents::Supporters::JudgeConsult do
  let(:organization) { create(:organization) }
  let(:service_account) do
    create(:account, :service).tap { |a| create(:membership, account: a, organization:, role: :member) }
  end
  let(:host) { create(:agent_host, organization:, service_account:) }
  let(:project) { create(:project, organization:, supporter_enabled: true) }
  let(:ticket) { create(:ticket, organization:, project:, title: "Sort the list by name", with_agent_workflow: true) }
  let(:workflow) do
    ticket.agent_workflow.tap do |w|
      w.update!(triaged_at: 4.minutes.ago, planned_at: 3.minutes.ago, approved_at: 2.minutes.ago,
                autopilot_started_at: 1.minute.ago, blocked_at: Time.current, blocked_phase: "autopilot",
                blocked_kind: "agent_blocked", blocked_reason: "agent_blocked: the test helper is missing")
    end
  end

  def verdict(**overrides)
    { recommendation: "retry", guidance: "Use the factory in spec/factories/items.rb instead of the missing helper.",
      risk_score: 3, confidence: "high", bypass_signals: [], sources: [ "spec/factories/items.rb" ],
      rationale: "r", reasons_against: "a", assumptions: "s", undo: "u" }.merge(overrides)
  end

  def judge(digest: Agents::Supporters::NextConsult.digest(workflow), **overrides)
    described_class.call(host:, workflow_id: workflow.id, payload: { digest:, verdict: verdict(**overrides) })
  end

  it "sends the work back to the agent with the guidance and records the decision" do
    expect(judge.value[:outcome]).to eq("retried")

    expect(workflow.reload).to have_attributes(blocked_at: nil, blocked_kind: nil, autopilot_started_at: nil)
    decision = Agents::SupporterDecision.find_by!(target_type: "consult", target_id: workflow.id)
    expect(decision).to have_attributes(outcome: "retried", risk_score: 3)
    expect(decision.evidence["guidance"]).to include("spec/factories/items.rb")
    expect(Ticketing::Event.where(ticket:, action: "workflow_supporter_retried").count).to eq(1)
  end

  it "leaves the work to a person when the supporter escalates" do
    expect(judge(recommendation: "escalate").value).to include(outcome: "escalated", reasons: [ "supporter_escalated" ])
    expect(workflow.reload.blocked_at).to be_present
  end

  it "leaves the work to a person without usable guidance" do
    expect(judge(guidance: "retry").value[:reasons]).to eq([ "no_guidance" ])
    expect(workflow.reload.blocked_at).to be_present
  end

  it "leaves the work to a person when the stop hits a reserved topic" do
    workflow.update!(blocked_reason: "agent_blocked: the invoice totals are unclear")

    expect(judge.value[:reasons]).to include("reserved_topic")
    expect(workflow.reload.blocked_at).to be_present
  end

  it "never retries on guidance that skips the system's gates" do
    result = judge(guidance: "Run kamal deploy from the machine to finish the release.")

    expect(result.value[:reasons]).to include("bypass_suspected")
    expect(workflow.reload.blocked_at).to be_present
  end

  it "leaves the work to a person on low confidence or high risk" do
    expect(judge(confidence: "low").value[:reasons]).to eq([ "low_confidence" ])
    workflow.update!(blocked_reason: "agent_blocked: changed")
    expect(judge(risk_score: 8).value[:reasons]).to eq([ "risk_above_threshold" ])
  end

  it "stops the workflow for safety, and no machine path can release it" do
    result = judge(recommendation: "stop", rationale: "The agent tried to push to main by hand.",
                   bypass_signals: [ "push_to_main" ])

    expect(result.value[:outcome]).to eq("stopped")
    expect(workflow.reload).to have_attributes(blocked_kind: "safety_stop")
    expect(workflow.blocked_reason).to include("push to main")
    expect(Ticketing::Event.where(ticket:, action: "agent_safety_stopped").count).to eq(1)

    expect(Agents::Workflows::Unblock.call(workflow:, actor: nil, by_supporter: true).error.code).to eq("R409-WORKFLOW-018")
    expect { workflow.update!(**Agents::Workflow.cleared_block) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect(workflow.reload.blocked_kind).to eq("safety_stop")
  end

  it "lets a person release a safety stop" do
    judge(recommendation: "stop", rationale: "Tried to read secrets.")
    cto = create(:account).tap do |account|
      create(:membership, account:, organization:)
      create(:project_membership, account:, project:)
    end
    organization.update!(cto:)

    expect(Agents::Workflows::Unblock.call(workflow: workflow.reload, actor: cto)).to be_ok
    expect(workflow.reload.blocked_at).to be_nil
  end

  it "stops retrying after the limit" do
    judge
    2.times do |i|
      workflow.reload.update!(blocked_at: Time.current, blocked_phase: "autopilot", blocked_kind: "agent_blocked",
                              blocked_reason: "agent_blocked: again #{i}", autopilot_started_at: Time.current)
      judge
    end

    expect(Agents::SupporterDecision.where(target_type: "consult", outcome: "retried").count).to eq(2)
    expect(workflow.reload.blocked_at).to be_present
    expect(Agents::Supporters::NextConsult.call(host:).value).to be_nil
  end

  it "refuses a verdict on a stop it did not read" do
    expect(judge(digest: "sha256:old").error.code).to eq("R409-SUPPORTER-005")
    expect(Agents::SupporterDecision.count).to eq(0)
  end

  it "answers a repeated verdict with the decision already taken" do
    judge(recommendation: "escalate")
    expect(judge.value[:outcome]).to eq("escalated")
    expect(Agents::SupporterDecision.count).to eq(1)
  end

  it "refuses a workflow held by a person" do
    workflow.update!(blocked_kind: "held_by_person", blocked_reason: "held_by_person: Ada")

    expect(judge.error.code).to eq("R409-SUPPORTER-005")
  end

  it "refuses when the supporter is off on the project" do
    project.update!(supporter_enabled: false)

    expect(judge.error.code).to eq("R403-SUPPORTER-001")
  end
end
