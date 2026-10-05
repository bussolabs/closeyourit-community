# frozen_string_literal: true

require "rails_helper"

# The review decision used to sit in a full-width band above the tabs. On a ticket whose automation
# also waits for a plan decision, the band and the plan card both offered approve and reject, for two
# different decisions, one above the other. The band is now a floating notice: it carries the review
# buttons only when no plan card is there to decide from.
RSpec.describe "Member ticket review notice", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:review_status) { create(:ticket_status, organization:, review_gate: true) }
  let(:ticket) { create(:ticket, organization:, project:, status: review_status, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:cto) { create(:account) }

  before do
    create(:membership, :owner, organization:, account: cto)
    create(:project_membership, project:, account: cto)
    organization.update!(cto:)
    create(:ticket_report, ticket:, organization:, body: "Done and verified.")
    post login_path, params: { email: cto.email, password: "Secret123!" }
  end

  def page_html(tab: nil)
    get member_ticket_path(ticket, tab:)
    Nokogiri::HTML(response.body)
  end

  it "is a floating notice, not a band in the content" do
    notice = page_html.at_css("aside[data-test='ticket-decision-banner']")

    expect(notice).to be_present
    expect(notice["data-controller"]).to eq("ui--floating-notice")
    expect(notice["class"]).to include("bg-emerald-50")
  end

  it "carries the review buttons when no plan card waits for a decision" do
    notice = page_html.at_css("[data-test='ticket-decision-banner']")

    expect(notice.at_css("[data-test='ticket-review-approve']")).to be_present
    expect(notice.at_css("[data-test='ticket-decision-see']")["href"]).to include("tab=report")
  end

  it "only points to the plan card when the automation waits for the plan" do
    attempt = create(:agent_attempt, organization:, workflow:)
    workflow.update!(triaged_at: 2.minutes.ago, planned_at: Time.current, ticket_snapshot_digest: "snapshot")
    Agents::Plan.create!(workflow:, attempt:, technical_analysis: "The plan", scenarios: [],
                         definition_of_done: [ "Specs green" ], notes: [], ticket_snapshot_digest: "snapshot")

    html = page_html(tab: "automation")
    notice = html.at_css("[data-test='ticket-decision-banner']")

    expect(notice).to be_present
    expect(notice.at_css("[data-test='ticket-review-approve']")).to be_nil
    expect(html.css("[data-test='ticket-review-approve']")).to be_empty
    expect(html.css("[data-test='automation-approve']").size).to eq(1)
  end
end
