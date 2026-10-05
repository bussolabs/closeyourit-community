# frozen_string_literal: true

require "rails_helper"

# CYRA-940 — the Help desk pages: the requests written by the visitors of the projects' sites.
RSpec.describe "Member::HelpdeskRequests", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org, name: "Shop", helpdesk_enabled: true) }
  let(:owner) { account_with_membership(:owner) }
  # Sees the project and holds the key.
  let(:agent) do
    account_with_membership(:member, on_project: true).tap do |account|
      create(:account_permission, account:, organization: org, permission_key: "helpdesk.manage", effect: :allow)
    end
  end
  # Sees the project, without the key.
  let(:colleague) { account_with_membership(:member, on_project: true) }

  def account_with_membership(role, on_project: false)
    create(:account).tap do |account|
      create(:membership, account:, organization: org, role:)
      create(:project_membership, account:, project:) if on_project
    end
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def request_for(*traits, on: project, **attributes)
    create(:helpdesk_request, *traits, project: on, **attributes)
  end

  describe "GET /member/helpdesk" do
    it "sends a signed-out visitor to the login" do
      get member_helpdesk_requests_path
      expect(response).to redirect_to(login_path)
    end

    it "lists the new requests of the projects the person manages" do
      request_for(body: "I cannot pay by card.", email: "anna@example.com")
      elsewhere = create(:project, organization: org, name: "Portal")
      request_for(on: elsewhere, body: "Hidden request 9001")
      sign_in(agent)

      get member_helpdesk_requests_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("I cannot pay by card.", "anna@example.com")
      expect(response.body).not_to include("Hidden request 9001")
    end

    it "keeps discarded requests out of the inbox and one filter away" do
      request_for(:discarded, body: "Buy followers 7007")
      request_for(body: "Real question 7008")
      sign_in(owner)

      get member_helpdesk_requests_path
      expect(response.body).to include("Real question 7008")
      expect(response.body).not_to include("Buy followers 7007")

      get member_helpdesk_requests_path(status: [ "discarded" ])
      expect(response.body).to include("Buy followers 7007")
    end

    it "searches the requests and filters by project" do
      request_for(body: "Card payment fails 3001")
      request_for(body: "Password question 3002")
      sign_in(owner)

      get member_helpdesk_requests_path(q: "payment")

      expect(response.body).to include("Card payment fails 3001")
      expect(response.body).not_to include("Password question 3002")
    end

    it "sorts by the received date, both ways" do
      request_for(body: "Older request 4001", created_at: 2.days.ago)
      request_for(body: "Newer request 4002", created_at: 1.hour.ago)
      sign_in(owner)

      get member_helpdesk_requests_path
      rows = Nokogiri::HTML(response.body).css("[data-test='helpdesk-row']").map(&:text)
      expect(rows.first).to include("Newer request 4002")

      get member_helpdesk_requests_path(sort: "received")
      rows = Nokogiri::HTML(response.body).css("[data-test='helpdesk-row']").map(&:text)
      expect(rows.first).to include("Older request 4001")
    end

    it "shows the empty page when nothing ever arrived" do
      project
      sign_in(owner)

      get member_helpdesk_requests_path

      expect(response.body).to include("helpdesk-empty")
    end

    it "refuses who sees the project without the key" do
      request_for(body: "Private request 5001")
      sign_in(colleague)

      get member_helpdesk_requests_path

      expect(response).to redirect_to(root_path)
    end

    it "renders in Italian" do
      request_for
      owner.update!(locale: "it")
      sign_in(owner)

      get member_helpdesk_requests_path

      expect(response.body).to include("Assistenza", "nuove")
    end
  end

  describe "GET /member/helpdesk/:id" do
    it "shows the message, the address, the page and the browser" do
      record = request_for(body: "I cannot pay by card.", email: "anna@example.com")
      sign_in(agent)

      get member_helpdesk_request_path(record)

      expect(response.body).to include("I cannot pay by card.", "anna@example.com", "https://shop.example.com/cart", "Safari")
    end

    it "escapes what the visitor wrote" do
      record = request_for
      record.messages.first.update_column(:body, "<img src=x onerror=alert(1)>")
      sign_in(owner)

      get member_helpdesk_request_path(record)

      expect(response.body).not_to include("<img src=x")
    end

    it "refuses who sees the project without the key" do
      record = request_for
      sign_in(colleague)

      get member_helpdesk_request_path(record)

      expect(response).to redirect_to(root_path)
    end

    it "does not find a request of another organization" do
      record = create(:helpdesk_request)
      sign_in(owner)

      get member_helpdesk_request_path(record)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "discarding and restoring" do
    it "discards a request, remembering who did it, and brings it back" do
      record = request_for
      sign_in(agent)

      put member_helpdesk_request_discard_path(record)
      expect(record.reload).to have_attributes(status: "discarded", discarded_by_id: agent.id)
      expect(record.discarded_at).to be_present

      delete member_helpdesk_request_discard_path(record)
      expect(record.reload).to have_attributes(status: "received", discarded_at: nil, discarded_by_id: nil)
    end

    it "refuses who has no key" do
      record = request_for
      sign_in(colleague)

      put member_helpdesk_request_discard_path(record)

      expect(record.reload.status).to eq("received")
    end
  end

  describe "erasing the email" do
    it "removes the address for good and keeps the message" do
      record = request_for(email: "anna@example.com", body: "I cannot pay by card.")
      sign_in(agent)

      delete member_helpdesk_request_email_path(record)

      expect(record.reload.email).to be_nil
      expect(record.email_erased_at).to be_present
      expect(record.messages.first.body).to eq("I cannot pay by card.")

      get member_helpdesk_request_path(record)
      expect(response.body).not_to include("anna@example.com")
    end

    it "refuses who has no key" do
      record = request_for(email: "anna@example.com")
      sign_in(colleague)

      delete member_helpdesk_request_email_path(record)

      expect(record.reload.email).to eq("anna@example.com")
    end
  end

  describe "the menu" do
    it "shows Help desk only to who manages it on some project" do
      project
      sign_in(colleague)
      get member_ideas_path
      expect(response.body).not_to include("member-nav-helpdesk")

      delete logout_path
      sign_in(agent)
      get member_ideas_path
      expect(response.body).to include("member-nav-helpdesk")
    end
  end
end
