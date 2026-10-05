# frozen_string_literal: true

require "rails_helper"

# CYRA-998 — the full-page plan is read by someone who does not have the code at hand: it opens with
# what happens on approval, and file references show their explanation, with the path only on hover.
RSpec.describe "Member::Home::Approvals#show plain reading", type: :request do
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

  def planned_workflow
    create(:agent_workflow, ticket: create(:ticket, organization: org, project:),
                            triage_requested_at: 2.days.ago, triaged_at: 1.day.ago, planned_at: Time.current)
  end

  def plan_for(workflow, decision_brief: nil, decision_card: nil)
    attempt = create(:agent_attempt, workflow:, organization: org, phase: "planner",
                                     result: decision_card ? { "decision_card" => decision_card } : {})
    Agents::Plan.create!(
      workflow:, attempt:, ticket_snapshot_digest: "snapshot", contract_version: 2,
      technical_analysis: "Projected analysis.", decision_brief:,
      content: {
        "summary" => "The summary of the plan.",
        "work_items" => [ { "id" => "WI-1", "title" => "New calculation", "description" => "Add the calculation.",
                            "files" => [ { "path" => "src/price.js", "line" => 2, "reason" => "The existing calculation lives here." } ],
                            "dependencies" => [] } ],
        "rationale" => [ "It mirrors the existing calculation." ],
        "risks" => [],
        "open_points" => [],
        "sources" => [ { "path" => "package.json", "line" => 7, "reason" => "Tests run without setup." } ]
      },
      scenarios: [], definition_of_done: [], notes: []
    )
  end

  def page_for(workflow)
    get member_home_approvals_item_path(kind: "agent_plan", id: workflow.id)
    Nokogiri::HTML(response.body)
  end

  describe "what happens on approval" do
    it "opens with the decision card, before the summary" do
      workflow = planned_workflow
      plan_for(workflow, decision_card: { "headline" => "A new price calculation arrives.",
                                          "points" => [ { "label" => "What changes", "text" => "One calculation more." } ],
                                          "risk_level" => "none", "risk" => nil })
      sign_in(owner)

      page = page_for(workflow)

      brief = page.at_css("[data-test='approvals-plan-if-approved']")
      expect(brief.text).to include("A new price calculation arrives.")
      expect(response.body.index("approvals-plan-if-approved")).to be < response.body.index("automation-plan-analysis")
    end

    it "shows the risk level on the section title row, not above the headline" do
      workflow = planned_workflow
      plan_for(workflow, decision_card: { "headline" => "A new price calculation arrives.",
                                          "points" => [ { "label" => "What changes", "text" => "One calculation more." } ],
                                          "risk_level" => "low", "risk" => nil })
      sign_in(owner)

      section = page_for(workflow).at_css("[data-test='approvals-plan-if-approved']")
      expect(section.at_css("[data-test='approvals-plan-if-approved-title'] [data-test='approvals-decision-card-level']")).to be_present
      expect(section.css("[data-test='approvals-decision-card-level']").size).to eq(1)
    end

    it "shows all four points of a bug card, the first one saying what happens today" do
      workflow = planned_workflow
      points = [ "What happens today", "What changes", "Why", "For app users" ].map { |label| { "label" => label, "text" => "#{label}." } }
      plan_for(workflow, decision_card: { "headline" => "The machine will report it is alive.", "points" => points,
                                          "risk_level" => "low", "risk" => nil })
      sign_in(owner)

      labels = page_for(workflow).css("[data-test='approvals-plan-if-approved'] [data-test='approvals-decision-card-point'] dt")
      expect(labels.map { |node| node.text.delete("→").squish }).to eq(points.pluck("label"))
    end

    it "falls back to the brief when the agent wrote no card" do
      workflow = planned_workflow
      plan_for(workflow, decision_brief: "A new price calculation arrives.")
      sign_in(owner)

      expect(page_for(workflow).at_css("[data-test='approvals-plan-if-approved']").text)
        .to include("A new price calculation arrives.")
    end

    it "is absent when the agent wrote neither" do
      workflow = planned_workflow
      plan_for(workflow)
      sign_in(owner)

      expect(page_for(workflow).at_css("[data-test='approvals-plan-if-approved']")).to be_nil
    end
  end

  describe "the plan on the page" do
    # CYRA-998 — the page showed version 1 after the agent wrote version 2.
    it "is the latest version" do
      workflow = planned_workflow
      plan_for(workflow, decision_brief: "First brief.")
      plan_for(workflow, decision_brief: "Rewritten brief.")
      sign_in(owner)

      expect(page_for(workflow).at_css("[data-test='approvals-plan-if-approved']").text).to include("Rewritten brief.")
    end
  end

  describe "file references" do
    it "show the explanation and keep the path only on hover" do
      workflow = planned_workflow
      plan_for(workflow)
      sign_in(owner)

      page = page_for(workflow)

      references = page.css("[data-test='automation-plan-file-reference']")
      expect(references.map { |node| node.text.squish }).to include(
        a_string_including("The existing calculation lives here."), a_string_including("Tests run without setup.")
      )
      expect(references.map { |node| node["title"] }).to contain_exactly("src/price.js:2", "package.json:7")
      expect(references.map(&:text).join).not_to include("src/price.js")
    end
  end
end
