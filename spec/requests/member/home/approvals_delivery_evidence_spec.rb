# frozen_string_literal: true

require "rails_helper"

# CYRA-886 — a delivery is judged on its evidence: counts first, marked as stated by the agent.
RSpec.describe "Member::Home::Approvals delivery evidence", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def page = Nokogiri::HTML(response.body)

  def delivered_workflow(result)
    ticket = create(:ticket, organization: org, project:)
    create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triaged_at: 1.day.ago, planned_at: 1.day.ago,
                            approved_at: 1.day.ago, autopilot_started_at: 1.day.ago,
                            autopilot_completed_at: Time.current, candidate_verified_at: Time.current).tap do |workflow|
      create(:agent_attempt, organization: org, workflow:, phase: "autopilot", status: :approved,
                             finished_at: Time.current, result:)
    end
  end

  def work_report(deviations: [])
    { "summary" => "Il resoconto si divide per progetto.", "commit" => "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29",
      "changed_files" => [ { "path" => "app/services/costs.rb", "summary" => "Divide per progetto." } ],
      "tests" => [ { "command" => "bin/rspec a", "status" => "passed", "summary" => "Verde." },
                   { "command" => "bin/rspec b", "status" => "failed", "summary" => "Rosso." } ],
      "risks" => [], "deviations" => deviations,
      "acceptance_evidence" => [
        { "criterion_id" => "DOD-1", "status" => "verified", "evidence" => "Test.", "source" => "reported" },
        { "criterion_id" => "DOD-2", "status" => "partial", "evidence" => "Metà.", "source" => "reported" }
      ] }
  end

  it "counts criteria and tests and says they are stated by the agent" do
    workflow = delivered_workflow({ "contract_version" => 2, "work_report" => work_report })
    sign_in(owner)

    get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

    evidence = page.at_css("[data-test='approvals-delivery-evidence']").text.squish
    expect(evidence).to include(I18n.t("member.approvals.evidence.criteria", done: 1, total: 2))
    expect(evidence).to include(I18n.t("member.approvals.evidence.tests", done: 1, total: 2))
    expect(evidence).to include(I18n.t("member.approvals.evidence.deviations", count: 0))
    expect(evidence).to include(I18n.t("member.approvals.evidence.reported"))
  end

  # CYRA-1284 — a check the agent did not run is not a failed check.
  it "shows a check that was not run in amber, never as a failure" do
    report = work_report.merge("tests" => [ { "command" => "bin/rspec a", "status" => "passed", "summary" => "Verde." },
                                            { "command" => "bin/rspec b", "status" => "not_run", "summary" => "Solo testo." } ])
    workflow = delivered_workflow({ "contract_version" => 2, "work_report" => report })
    sign_in(owner)

    get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

    evidence = page.at_css("[data-test='approvals-delivery-evidence']")
    expect(evidence.text.squish).to include(I18n.t("member.approvals.evidence.tests_not_run", count: 1))
    expect(evidence.text.squish).not_to include(I18n.t("member.approvals.evidence.tests_failed", count: 1))
    expect(evidence.to_html).not_to include("bg-red-50")
  end

  it "keeps a failed check red and counts it" do
    workflow = delivered_workflow({ "contract_version" => 2, "work_report" => work_report })
    sign_in(owner)

    get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

    evidence = page.at_css("[data-test='approvals-delivery-evidence']")
    expect(evidence.text.squish).to include(I18n.t("member.approvals.evidence.tests_failed", count: 1))
    expect(evidence.to_html).to include("bg-red-50")
  end

  # CYRA-1287 — with the agent's short card the page says each thing once: the long report is one link away.
  describe "the full page of a delivery" do
    let(:card) do
      { "headline" => "Il resoconto dei costi ora si divide per progetto.",
        "points" => [ { "label" => "Cosa è stato fatto", "text" => "Una colonna per progetto." } ],
        "risk_level" => "none", "risk" => nil }
    end

    it "replaces the long report with links when the short card is there" do
      workflow = delivered_workflow({ "contract_version" => 2, "work_report" => work_report, "decision_card" => card })
      sign_in(owner)

      get member_home_approvals_item_path(kind: "agent_plan", id: workflow.id)

      expect(page.at_css("[data-test='approvals-decision-card-headline']")).to be_present
      expect(page.at_css("[data-test='approvals-detail-report']")).to be_nil
      links = page.css("[data-test='approvals-delivery-more'] a").map { |link| link["href"] }
      expect(links).to include(member_ticket_path(workflow.ticket, tab: "report"), member_ticket_path(workflow.ticket))
    end

    it "keeps the long report when there is no short card to stand for it" do
      workflow = delivered_workflow({ "contract_version" => 2, "work_report" => work_report })
      sign_in(owner)

      get member_home_approvals_item_path(kind: "agent_plan", id: workflow.id)

      expect(page.at_css("[data-test='approvals-detail-report']")).to be_present
      expect(page.at_css("[data-test='approvals-delivery-more']")).to be_nil
    end
  end

  it "shows every deviation in full" do
    deviation = { "title" => "Colonna rinominata", "reason" => "Evitare un doppione.", "impact" => "Cambia l'intestazione." }
    workflow = delivered_workflow({ "contract_version" => 2, "work_report" => work_report(deviations: [ deviation ]) })
    sign_in(owner)

    get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

    expect(page.at_css("[data-test='approvals-delivery-deviation']").text).to include("Colonna rinominata", "Cambia l'intestazione.")
  end

  it "shows the agent's decision card for the delivery when there is one" do
    card = { "headline" => "Il resoconto dei costi ora si divide per progetto.",
             "points" => [ { "label" => "Cosa è stato fatto", "text" => "Una colonna per progetto." } ],
             "risk_level" => "none", "risk" => nil }
    workflow = delivered_workflow({ "contract_version" => 2, "work_report" => work_report, "decision_card" => card })
    sign_in(owner)

    get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

    expect(page.at_css("[data-test='approvals-decision-card-headline']").text).to include(card["headline"])
  end
end
