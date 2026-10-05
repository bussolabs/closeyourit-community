# frozen_string_literal: true

require "rails_helper"

# CYRA-862 — in home si decide anche da tastiera: a approva, r apre il rifiuto, s salta, d rimanda.
RSpec.describe "Member home — tasti della decisione", type: :system do
  let(:org) { create(:organization, name: "Demo Org") }
  let(:owner) { create(:account, name: "Olivia") }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
  end

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
    expect(page).to have_no_css("[data-test='login-submit']", wait: 8)
  end

  def plan_card(title:, planned_at:)
    ticket = create(:ticket, organization: org, project:, title:)
    workflow = create(:agent_workflow, ticket:, triage_requested_at: 3.days.ago, triaged_at: 2.days.ago, planned_at:)
    attempt = create(:agent_attempt, workflow:, organization: org, phase: "planner")
    Agents::Plan.create!(
      workflow:, attempt:, ticket_snapshot_digest: "snapshot", contract_version: 2,
      technical_analysis: "Analisi.", decision_brief: "Brief di #{title}.",
      content: { "summary" => "Sintesi.", "work_items" => [], "rationale" => [], "risks" => [],
                 "open_points" => [], "sources" => [] },
      scenarios: [ { "id" => "SC-1", "title" => "Uno", "given" => "a", "when" => "b", "then" => "c", "expected" => "d" } ],
      definition_of_done: [ { "id" => "DOD-1", "text" => "Fatto" } ], notes: []
    )
  end

  context "aiuto da tastiera (markup)" do
    before { driven_by(:rack_test) }

    it "la scheda monta i tasti e li dichiara nell'aiuto" do
      plan_card(title: "Primo piano", planned_at: 2.days.ago)
      sign_in_as(owner)

      visit root_path

      wrapper = find("[data-controller~='decision-keys']")
      docs = JSON.parse(wrapper["data-keyboard-doc"])
      expect(docs.map { |doc| doc["keys"] }).to eq(%w[a r s d])
    end
  end

  context "comportamento (browser reale)", js: true do
    it "s salta la scheda e mostra quella dopo" do
      plan_card(title: "Primo piano", planned_at: 2.days.ago)
      plan_card(title: "Secondo piano", planned_at: 1.day.ago)
      sign_in_as(owner)

      visit root_path
      expect(page).to have_css("[data-test='decision-subject']", text: "Primo piano")

      find("body").send_keys("s")

      expect(page).to have_css("[data-test='decision-subject']", text: "Secondo piano")
    end

    it "a approva la scheda davanti" do
      plan = plan_card(title: "Primo piano", planned_at: 2.days.ago)
      sign_in_as(owner)

      visit root_path
      expect(page).to have_css("[data-test='decision-subject']", text: "Primo piano")

      find("body").send_keys("a")

      expect(page).to have_no_css("[data-test='decision-subject']", text: "Primo piano")
      expect(plan.reload.approved_by_id).to eq(owner.id)
    end

    it "r apre il motivo del rifiuto senza inviare niente" do
      plan_card(title: "Primo piano", planned_at: 2.days.ago)
      sign_in_as(owner)

      visit root_path
      find("body").send_keys("r")

      expect(page).to have_css("[data-test='approvals-reject-reason']:focus")
      expect(page).to have_css("[data-test='decision-subject']", text: "Primo piano")
    end

    it "mentre si scrive nella nota i tasti non fanno niente" do
      plan_card(title: "Primo piano", planned_at: 2.days.ago)
      sign_in_as(owner)

      visit root_path
      find("[data-test='approvals-note'] summary").click
      find("[data-test='approvals-approve-note']").send_keys("sad")

      expect(page).to have_css("[data-test='decision-subject']", text: "Primo piano")
      expect(find("[data-test='approvals-approve-note']").value).to eq("sad")
    end
  end
end
