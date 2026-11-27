# frozen_string_literal: true

require "rails_helper"

# CYRA-1193 — the supporter judges a plan, the server decides whether it is approved without a person.
# CYRA-1345 — a reason a person used to decide on is a warning: the plan is approved and the person is told.
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

  # CYRA-1293 — the triage's risk is the floor under the supporter's score, when the project switches it on.
  describe "the risk the triage set" do
    def triage_said(result)
      create(:agent_attempt, organization:, workflow:, phase: "triage", result:, created_at: 5.minutes.ago)
    end

    it "is ignored while the rule is off" do
      triage_said({ "risk" => "high" })

      expect(judge.value).to include(outcome: "approved", risk_score: 3)
    end

    it "approves the plan of a high-risk ticket with a warning" do
      project.update!(triage_risk_floor: "on")
      triage_said({ "risk" => "high" })

      result = judge

      expect(result.value).to include(outcome: "approved", risk_score: 9)
      expect(result.value[:reasons]).to include("risk_above_threshold", "triage_risk")
      expect(workflow.reload.approved_at).to be_present
    end

    it "raises the score of a medium-risk ticket and still approves" do
      project.update!(triage_risk_floor: "on")
      triage_said({ "risk" => "medium" })

      expect(judge.value).to include(outcome: "approved", risk_score: 4)
    end

    it "approves in a dry run and writes what the rule would have set" do
      project.update!(triage_risk_floor: "dry_run")
      triage_said({ "risk" => "high" })

      expect(judge.value).to include(outcome: "approved", risk_score: 3)
      expect(Agents::SupporterDecision.find_by!(target_type: "plan", target_id: plan.id).evidence)
        .to include("triage_floor" => 9, "triage_floor_mode" => "dry_run")
    end
  end

  # CYRA-1345 — the reasons a person used to decide on are a warning now: the plan goes ahead and the
  # person is told, in the ticket's history and with a notice.
  describe "a plan with a reason a person should know about" do
    it "is approved when the supporter asks for a person, and the gaps travel as notes" do
      result = judge(recommendation: "escalate", reasons_against: "Nobody chose the retention period.")

      expect(result.value).to include(outcome: "approved", reasons: [ "supporter_escalated" ])
      expect(workflow.reload).to have_attributes(approved_by_id: nil, frozen_plan_id: plan.id)
      expect(Agents::SupporterDecision.find_by!(target_id: plan.id).evidence["guidance"])
        .to include("Nobody chose the retention period.")
    end

    it "writes the warnings and the risk in the ticket's history" do
      judge(risk_score: 9)

      expect(Ticketing::Event.find_by!(ticket:, action: "plan_supporter_approved").data)
        .to eq("warnings" => [ "risk_above_threshold" ], "risk_score" => 9)
    end

    it "tells a person with a notice" do
      expect { judge(risk_score: 9) }.to have_enqueued_job(Agents::PlanWarningJob)
        .with { |decision_id| expect(decision_id).to eq(Agents::SupporterDecision.find_by!(target_id: plan.id).id) }
    end

    it "sends no notice for a plan approved with no reason" do
      expect { judge }.not_to have_enqueued_job(Agents::PlanWarningJob)
      expect(Ticketing::Event.find_by!(ticket:, action: "plan_supporter_approved").data).to eq({})
    end

    it "still waits for a person on a project with strict caps" do
      project.update!(strict_caps: "1")

      expect { judge(risk_score: 9) }.not_to have_enqueued_job(Agents::PlanWarningJob)
      expect(judge(risk_score: 9).value).to include(outcome: "escalated", reasons: [ "risk_above_threshold" ])
      expect(workflow.reload.approved_at).to be_nil
    end
  end

  it "raises the score on CI and secrets paths and approves with a warning" do
    result = judge(touched_paths: [ ".kamal/secrets-common" ])

    expect(result.value).to include(outcome: "approved", risk_score: 9)
    expect(result.value[:reasons]).to include("risk_above_threshold")
    expect(workflow.reload.approved_at).to be_present
  end

  # CYRA-1197 — the content decides: an additive migration the supporter checked is not a reason by itself.
  it "lets the supporter approve a plan that touches database paths" do
    result = judge(touched_paths: [ "db/migrate/20261104000000_add_rank.rb" ])

    expect(result.value).to include(outcome: "approved", risk_score: 7)
  end

  # CYRA-1326 — what customers read is no longer a reserved topic, so a low-risk wording change needs no person.
  it "approves a plan that changes what customers read" do
    ticket.update!(title: "Reword the customer-facing empty state", description: "Mentions the privacy page too.")

    expect(judge(confidence: "medium").value).to include(outcome: "approved")
    expect(workflow.reload.approved_at).to be_present
  end

  it "approves a plan that changes the payments with a warning" do
    ticket.update!(title: "Retry a failed payment once")

    result = judge(confidence: "medium")

    expect(result.value).to include(outcome: "approved", risk_score: 10)
    expect(result.value[:reasons]).to include("reserved_topic")
    expect(workflow.reload.approved_at).to be_present
  end

  it "warns when the plan hits a reserved topic the supporter did not clear" do
    ticket.update!(title: "Change the invoice totals")

    expect(judge(recommendation: "escalate").value).to include(outcome: "approved")
    expect(judge(recommendation: "escalate").value[:reasons]).to include("reserved_topic")
  end

  it "warns when the reserved topic is in a file the plan touches" do
    project.update!(supporter_reserved_topics: "app/models/billing/")

    result = judge(touched_paths: [ "app/models/billing/invoice.rb" ])

    expect(result.value).to include(outcome: "approved", risk_score: 10)
    expect(result.value[:reasons]).to include("reserved_topic")
  end

  it "warns when the text hits a topic the project reserved" do
    project.update!(supporter_reserved_topics: "sorting")
    ticket.update!(title: "Change the sorting of the list")

    expect(judge.value[:reasons]).to include("reserved_topic")
    expect(workflow.reload.approved_at).to be_present
  end

  # CYRA-1197 — a built-in word in the text ("billing", "pagamento") does not stop a plan the supporter read and
  # approved with high confidence: it judged the content, and the word alone is not a change to money.
  it "approves a plan whose text only mentions a built-in reserved word when the supporter clears it" do
    ticket.update!(title: "Billing page shows a 0 € offer that cannot exist")

    result = judge

    expect(result.value).to include(outcome: "approved", risk_score: 3)
    expect(Agents::SupporterDecision.find_by!(target_id: plan.id).evidence["reserved_matches"]).to include("billing")
  end

  it "clears a built-in word with medium confidence only when the risk is minimal" do
    ticket.update!(title: "Guest 404 page mentions the payment link")

    expect(judge(confidence: "medium", risk_score: 2).value).to include(outcome: "approved")
  end

  it "keeps a built-in word in front of a medium-confidence plan above minimal risk" do
    ticket.update!(title: "Guest 404 page mentions the payment link")

    expect(judge(confidence: "medium", risk_score: 3).value[:reasons]).to include("reserved_topic")
  end

  # CYRA-1197
  it "stops the workflow for safety when the supporter finds the plan skips the system's gates" do
    result = judge(recommendation: "stop", rationale: "The plan deploys with kamal from the machine.")

    expect(result.value[:outcome]).to eq("stopped")
    expect(workflow.reload).to have_attributes(blocked_kind: "safety_stop", approved_at: nil)
    expect(Ticketing::Event.where(ticket:, action: "agent_safety_stopped").count).to eq(1)
  end

  it "never approves a plan that proposes to skip the system's gates" do
    plan.update_columns(technical_analysis: "Finish with git push --force origin main.")

    result = judge(digest: Agents::Supporters::NextPlan.digest(plan.reload))

    expect(result.value[:reasons]).to include("bypass_suspected")
    expect(workflow.reload.approved_at).to be_nil
  end

  # CYRA-1197 — a plan with fixable gaps goes back to the planner instead of waiting for a person.
  it "sends a plan with fixable gaps back to the planner with the supporter's findings" do
    result = judge(recommendation: "revise", risk_score: 10, reasons_against: "The check for the empty list is missing.")

    expect(result.value[:outcome]).to eq("retried")
    expect(plan.reload.change_request).to include("The check for the empty list is missing.")
    expect(workflow.reload).to have_attributes(planned_at: nil, approved_at: nil, blocked_at: nil)
  end

  it "does not send a plan back a second time" do
    Agents::SupporterDecision.create!(organization:, workflow:, target_type: "plan", target_id: SecureRandom.uuid,
                                      target_digest: "old", outcome: "retried", engine: "codex", risk_score: 5)

    expect(judge(recommendation: "revise").value[:outcome]).not_to eq("retried")
  end

  # CYRA-1345 — after the allowed revision the plan is not sent back again: it goes ahead with the gaps as
  # notes and a warning, whatever its risk. The budget is settled by the server (CYRA-1327) only where the
  # plan still waits for a person.
  it "approves the plan with a warning after the revision asked by the supporter" do
    described_class::MAX_REVISIONS.times do |i|
      Agents::SupporterDecision.create!(organization:, workflow:, target_type: "plan", target_id: SecureRandom.uuid,
                                        target_digest: "old-#{i}", outcome: "retried", engine: "codex", risk_score: 5)
    end

    result = nil
    expect { result = judge(recommendation: "revise", risk_score: 6, reasons_against: "Name the migration file.") }
      .not_to have_enqueued_job(Agents::ExhaustedBudgetJob)

    expect(result.value).to include(outcome: "approved")
    expect(result.value[:reasons]).to include("revisions_exhausted")
    expect(plan.reload.change_request).to be_blank
    expect(Agents::SupporterDecision.find_by!(target_id: plan.id).evidence["guidance"]).to include("Name the migration file.")
  end

  # AC-3, AC-7 — a reserved topic, a suspected bypass or a risk above the line keep the hand-over: the
  # budget is not the only reason a person is wanted.
  it "leaves an exhausted plan to a person when something else also wants one" do
    described_class::MAX_REVISIONS.times do |i|
      Agents::SupporterDecision.create!(organization:, workflow:, target_type: "plan", target_id: SecureRandom.uuid,
                                        target_digest: "old-#{i}", outcome: "retried", engine: "codex", risk_score: 5)
    end

    expect { judge(recommendation: "revise", risk_score: 10) }
      .not_to have_enqueued_job(Agents::ExhaustedBudgetJob)
  end

  # CYRA-1197 — after three rounds the remaining gaps of a low-risk plan travel to the implementer as notes;
  # review, CI and the staging soak still stand between the work and production.
  it "approves a low-risk plan after the revision and keeps the gaps as notes for the implementer" do
    described_class::MAX_REVISIONS.times do |i|
      Agents::SupporterDecision.create!(organization:, workflow:, target_type: "plan", target_id: SecureRandom.uuid,
                                        target_digest: "old-#{i}", outcome: "retried", engine: "codex", risk_score: 4)
    end

    result = judge(recommendation: "revise", risk_score: 5, reasons_against: "Name the migration file.")

    expect(result.value).to include(outcome: "approved", reasons: [])
    expect(workflow.reload.approved_at).to be_present
    expect(Agents::SupporterDecision.find_by!(target_id: plan.id).evidence["guidance"]).to include("Name the migration file.")
  end

  # CYRA-1299 — a project with strict caps keeps that plan for a person.
  it "leaves an exhausted low-risk plan to a person when the project has strict caps" do
    project.update!(strict_caps: "1")
    described_class::MAX_REVISIONS.times do |i|
      Agents::SupporterDecision.create!(organization:, workflow:, target_type: "plan", target_id: SecureRandom.uuid,
                                        target_digest: "old-#{i}", outcome: "retried", engine: "codex", risk_score: 4)
    end

    result = nil
    expect { result = judge(recommendation: "revise", risk_score: 5, reasons_against: "Name the migration file.") }
      .not_to have_enqueued_job(Agents::ExhaustedBudgetJob)

    expect(result.value[:outcome]).to eq("escalated")
    expect(workflow.reload.approved_at).to be_nil
  end

  it "never approves an exhausted plan that proposes to skip the system's gates" do
    described_class::MAX_REVISIONS.times do |i|
      Agents::SupporterDecision.create!(organization:, workflow:, target_type: "plan", target_id: SecureRandom.uuid,
                                        target_digest: "old-#{i}", outcome: "retried", engine: "codex", risk_score: 4)
    end
    plan.update_columns(technical_analysis: "Finish with git push --force origin main.")

    result = judge(digest: Agents::Supporters::NextPlan.digest(plan.reload), recommendation: "revise", risk_score: 2)

    expect(result.value[:outcome]).to eq("escalated")
    expect(workflow.reload.approved_at).to be_nil
  end

  it "keeps the notes the supporter writes for the implementer when it approves" do
    judge(implementation_notes: "Keep the existing wording when unsure.")

    expect(Agents::SupporterDecision.find_by!(target_id: plan.id).evidence["guidance"])
      .to eq("Keep the existing wording when unsure.")
  end

  it "never sends back for revision a plan that proposes to skip the system's gates" do
    plan.update_columns(technical_analysis: "Finish with git push --force origin main.")

    result = judge(digest: Agents::Supporters::NextPlan.digest(plan.reload), recommendation: "revise")

    expect(result.value[:outcome]).to eq("escalated")
    expect(plan.reload.change_request).to be_blank
  end

  it "leaves the plan to a person on low confidence" do
    expect(judge(confidence: "low").value[:reasons]).to eq([ "low_confidence" ])
  end

  # CYRA-1152 — approving an epic's split creates tickets: always a person's yes.
  it "leaves an epic's split to a person" do
    ticket.update!(kind: :epic)
    children = %w[CH-1 CH-2].map do |id|
      { "id" => id, "title" => "Child #{id}", "description" => "Work.", "dependencies" => [],
        "scenarios" => [ { "id" => "SC-1", "title" => "Works", "given" => "a", "when" => "b", "then" => "c", "expected" => "d" } ] }
    end
    plan.update_columns(contract_version: 2, content: { "summary" => "Split", "children" => children })

    expect(judge.value).to include(outcome: "escalated", reasons: [ "epic_split" ])
    expect(workflow.reload.approved_at).to be_nil
  end

  # CYRA-1334 — a new acceptance item the plan proposes is accepted without a person when nothing else
  # stops the plan; an item left unproven still waits for a person (CYRA-1319).
  describe "a plan that changes the ticket's acceptance items" do
    let(:proof) { { "kind" => "test", "how" => "A request spec opens the page." } }
    let(:new_item) { { "ref" => "NEW-1", "format" => "text", "text" => "The list keeps its order after a reload", "verification" => proof } }

    before { ticket.conditions.create!(position: 1, text: "The list is sorted") }

    def write_items(verifications: ticket.acceptance_items.map { { "code" => it.code, "revision" => it.revision, "verification" => proof } },
                    proposed: [])
      result = { "item_verifications" => verifications, "proposed_items" => proposed }
      plan.update_columns(contract_version: 3, content: { "summary" => "Sort the list.", "work_items" => [] },
                          definition_of_done: Agents::Plans::TicketItems.snapshot(ticket, result))
    end

    it "approves a low-risk plan that proposes a new item and writes it into the ticket" do
      write_items(proposed: [ new_item ])

      expect(judge.value[:outcome]).to eq("approved")
      expect(ticket.conditions.reload.map(&:text)).to include("The list keeps its order after a reload")
      added = ticket.acceptance_items.reload.map(&:code).last
      expect(Ticketing::Event.find_by!(ticket:, action: "plan_supporter_added_items").data).to eq("items" => [ added ])
    end

    it "records no added items when the plan proposes none" do
      write_items

      expect(judge.value[:outcome]).to eq("approved")
      expect(Ticketing::Event.where(ticket:, action: "plan_supporter_added_items")).not_to exist
    end

    it "approves a plan that leaves an item unproven with a warning" do
      write_items(verifications: [])

      expect(judge.value).to include(outcome: "approved", reasons: [ "ticket_items_need_person" ])
      expect(workflow.reload.approved_at).to be_present
    end

    it "approves a proposing plan above the autonomous risk with a warning and adds its item" do
      write_items(proposed: [ new_item ])

      expect(judge(risk_score: 9).value).to include(outcome: "approved", reasons: [ "risk_above_threshold" ])
      expect(ticket.conditions.reload.count).to eq(2)
    end
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
