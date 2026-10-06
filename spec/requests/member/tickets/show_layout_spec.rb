# frozen_string_literal: true

require "rails_helper"

# CYRA-883 — the ticket page reorganised: the project once, audit at the bottom, compact side panels
# grouped by question (Connections, Context), empty things out of the way.
RSpec.describe "Member ticket page layout", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org, name: "Payments API") }
  let(:status) { create(:ticket_status, organization: org) }
  let(:priority) { create(:ticket_priority, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project, status: status, priority: priority) }
  let(:owner) { account_with(:owner) }
  let(:viewer) { account_with(:customer, on_project: true) }

  def account_with(role, on_project: false)
    create(:account).tap do |account|
      create(:membership, account: account, organization: org, role: role)
      create(:project_membership, account: account, project: project) if on_project
    end
  end

  def doc = Nokogiri::HTML(response.body)
  def test_id(id) = doc.at_css("[data-test='#{id}']")

  def sign_in(account) = post(login_path, params: { email: account.email, password: "Secret123!" })

  def show(as: owner, **params)
    sign_in(as)
    get member_ticket_path(ticket, **params)
  end

  describe "header" do
    it "keeps only the code in the breadcrumb, the project stays under the title" do
      show

      expect(doc.css("[data-test='breadcrumb-crumb']").last.text.strip).to eq(ticket.code)
      expect(test_id("ticket-code").text).to include(ticket.code)
      expect(test_id("ticket-project").text).to include("Payments API")
    end

    it "shows vote and watch as icon and number, with the label kept for screen readers" do
      show

      vote = test_id("ticket-vote")
      expect(vote.text.strip).to eq("0")
      expect(vote["aria-label"]).to be_present
      watch = test_id("ticket-watch")
      expect(watch.text.gsub(/\s+/, "")).to eq("0")
      expect(watch["aria-label"]).to be_present
    end

    it "puts take-over on the left, under the assignee label" do
      show

      expect(doc.at_css("[data-test='detail-assignee-label'] [data-test='ticket-lease-take']")).to be_present
      expect(doc.css("[data-test='ticket-lease-take']").size).to eq(1)
    end
  end

  describe "side column" do
    it "does not repeat the project in Details" do
      show

      expect(test_id("detail-project")).to be_nil
    end

    it "moves created, updated and history to the bottom of the page" do
      show

      expect(doc.at_css("[data-test='ticket-page-footer'] [data-test='ticket-audit']")).to be_present
      expect(doc.at_css("[data-test='ticket-details'] [data-test='ticket-audit']")).to be_nil
    end

    it "keeps the footer as the last block of the page, so it touches the frame edge" do
      show

      expect(doc.at_css("[data-test='member-ticket']").element_children.last["data-test"]).to eq("ticket-page-footer")
    end

    it "groups dependencies, links and children in one Connections section" do
      show

      expect(doc.at_css("[data-test='ticket-connections'] [data-test='ticket-dependencies']")).to be_present
    end

    it "leaves Connections out when there is nothing to show or add" do
      show(as: viewer)

      expect(test_id("ticket-connections")).to be_nil
    end

    it "groups origin error, linked logs and knowledge in one Context section" do
      create(:error_group, project: project, title: "RuntimeError: boom", ticket: ticket)
      entry = create(:log_entry, project: project, message: "checkout timeout")
      create(:log_link, log_entry: entry, linkable: ticket)

      show

      context = test_id("ticket-context")
      expect(context.at_css("[data-test='ticket-error-origin']")).to be_present
      expect(context.at_css("[data-test='linked-log-entries']")).to be_present
      expect(context.at_css("[data-test='knowledge-related']")).to be_present
    end

    it "hides the linked logs when there are none" do
      create(:error_group, project: project, ticket: ticket)

      show

      expect(test_id("linked-log-entries")).to be_nil
      expect(test_id("ticket-context")).to be_present
    end

    it "keeps related knowledge on its own when there is no origin and no linked log" do
      show

      expect(test_id("ticket-context")).to be_nil
      expect(test_id("knowledge-related")).to be_present
    end
  end

  describe "main column" do
    it "shows an empty attachments list as one row, with the upload behind a click" do
      show

      row = test_id("member-ticket-attachments-compact")
      expect(row).to be_present
      expect(row.at_css("details [data-test='member-ticket-attachment-form']")).to be_present
    end

    it "keeps comments out of the detail tab: the thread lives in Discussion" do
      create(:ticket_comment, ticket: ticket, author: owner, body: "Hello")

      show

      expect(test_id("ticket-recent-comments")).to be_nil
    end
  end

  describe "tabs" do
    it "hides the technical analysis tab while it is empty" do
      show

      expect(test_id("ticket-tab-analysis")).to be_nil
      expect(test_id("ticket-tab-questions")).to be_present
    end

    it "shows the technical analysis tab once it has content" do
      ticket.update!(technical_analysis: "Root cause: nil amount.")

      show

      expect(test_id("ticket-tab-analysis")).to be_present
    end
  end
end
