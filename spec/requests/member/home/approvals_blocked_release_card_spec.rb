# frozen_string_literal: true

require "rails_helper"

# CYRA-1082 — the card of a blocked release reads in order: what stopped it, in plain words, then the
# requeue button, then what the release contains, with the risk level on the section row.
RSpec.describe "Member::Home::Approvals blocked release card", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:raw_reason) { "Tag v0.189.0 already exists on 2a5840f41d5cc518aa5c61b89b49a33a9e09e2d1." }
  let(:plain_reason) { "Il rilascio v0.189.0 è fermo: esiste già una versione con lo stesso numero." }
  let(:decision_card) do
    { "headline" => "Il progetto non installerà più 2 librerie che nessuno usa.",
      "points" => [ { "label" => "Cosa cambia", "text" => "Si tolgono 2 librerie mai usate." } ],
      "risk_level" => "low", "risk" => "Se una parte nascosta usasse una libreria, le prove lo scoprono." }
  end

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def blocked_workflow(phase:, result:)
    ticket = create(:ticket, organization: org, project:)
    workflow = create(:agent_workflow, ticket:, triage_requested_at: 3.days.ago, triaged_at: 3.days.ago,
                                       planned_at: 2.days.ago, approved_at: 2.days.ago, blocked_at: Time.current,
                                       blocked_phase: phase, blocked_kind: "attempt_limit")
    planner = create(:agent_attempt, workflow:, organization: org, phase: "planner",
                                     result: { "decision_card" => decision_card })
    Agents::Plan.create!(workflow:, attempt: planner, ticket_snapshot_digest: "snapshot", contract_version: 2,
                         technical_analysis: "Analysis.", content: { "summary" => "Remove two gems." },
                         scenarios: [], definition_of_done: [], notes: [])
    create(:agent_attempt, workflow:, organization: org, phase:, status: :review_failed, result:,
                           review: { "summary" => "La revisione è d'accordo: è giusto fermarsi." },
                           review_status: :changes_requested)
    workflow
  end

  def open_card(workflow)
    sign_in(owner)
    get member_home_approvals_path(item: "agent_plan:#{workflow.id}")
    Nokogiri::HTML(response.body)
  end

  it "shows the plain reason instead of the raw one" do
    page = open_card(blocked_workflow(phase: "closer_production",
                                      result: { "state" => "blocked", "reason" => raw_reason, "plain_reason" => plain_reason }))

    expect(page.at_css("[data-test='approvals-detail-attempt-text']").text).to include(plain_reason)
    expect(response.body).not_to include("2a5840f41d5cc518aa5c61b89b49a33a9e09e2d1")
  end

  it "falls back to the raw reason when the agent wrote no plain one" do
    page = open_card(blocked_workflow(phase: "closer_production", result: { "state" => "blocked", "reason" => raw_reason }))

    expect(page.at_css("[data-test='approvals-detail-attempt-text']").text).to include(raw_reason)
  end

  it "puts the requeue button after the reason and the review" do
    page = open_card(blocked_workflow(phase: "closer_production", result: { "state" => "blocked", "reason" => raw_reason }))

    attempt = page.at_css("[data-test='approvals-detail-attempt']")
    expect(attempt.at_css("[data-test='approvals-requeue']")).to be_present
    expect(page.css("[data-test='approvals-requeue']").size).to eq(1)
  end

  it "shows the risk level on the section row, not above the headline" do
    page = open_card(blocked_workflow(phase: "closer_production", result: { "state" => "blocked", "reason" => raw_reason }))

    title_row = page.at_css("[data-test='approvals-plan-section-title']")
    expect(title_row.at_css("[data-test='approvals-decision-card-level']")).to be_present
    expect(page.css("[data-test='approvals-decision-card-level']").size).to eq(1)
  end

  it "titles the plan section as the release content on a blocked release" do
    page = open_card(blocked_workflow(phase: "closer_staging", result: { "state" => "blocked", "reason" => raw_reason }))

    expect(page.at_css("[data-test='approvals-plan-section-title']").text)
      .to include(I18n.t("member.approvals.compact.release_contents"))
  end

  it "keeps «if approved» when the blocked phase is not a release" do
    page = open_card(blocked_workflow(phase: "autopilot", result: { "state" => "blocked", "reason" => raw_reason }))

    expect(page.at_css("[data-test='approvals-plan-section-title']").text)
      .to include(I18n.t("member.approvals.compact.if_approved"))
  end
end
