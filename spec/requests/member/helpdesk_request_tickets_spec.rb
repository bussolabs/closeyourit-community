# frozen_string_literal: true

require "rails_helper"

# CYRA-941 — a help desk request becomes a ticket, or joins one that already exists.
RSpec.describe "Member::HelpdeskRequests tickets", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org, name: "Shop", key: "SHOP", helpdesk_enabled: true) }
  let(:owner) { account_with_membership(:owner) }
  # Sees the project, without the help desk key.
  let(:colleague) { account_with_membership(:member, on_project: true) }
  let(:request_record) { create(:helpdesk_request, project: project, body: "I cannot pay by card 4411.", email: "anna@example.com") }

  before { Types::InstallDefaults.call(organization: org) }

  def account_with_membership(role, on_project: false)
    create(:account).tap do |account|
      create(:membership, account:, organization: org, role:)
      create(:project_membership, account:, project:) if on_project
    end
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "turning a request into a ticket" do
    it "shows a draft with the visitor's words and never the address" do
      sign_in(owner)

      get new_member_helpdesk_request_conversion_path(request_record)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("I cannot pay by card 4411.", "https://shop.example.com/cart")
      expect(response.body).not_to include("anna@example.com")
    end

    it "creates the ticket with the person who triages as reporter" do
      sign_in(owner)

      expect do
        post member_helpdesk_request_conversion_path(request_record),
             params: { title: "Card payment fails", description: "The checkout refuses the card.", kind: "bug" }
      end.to change(Ticketing::Ticket, :count).by(1)

      ticket = Ticketing::Ticket.order(:created_at).last
      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(ticket).to have_attributes(title: "Card payment fails", reporter: owner, project: project)
      expect(request_record.reload).to be_status_converted
      expect(request_record.ticket).to eq(ticket)
    end

    it "shows the form again when the ticket is not valid" do
      sign_in(owner)

      expect do
        post member_helpdesk_request_conversion_path(request_record), params: { title: "Card payment fails", description: "" }
      end.not_to change(Ticketing::Ticket, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(request_record.reload).to be_status_received
    end

    it "does not convert twice" do
      ticket = create(:ticket, project: project)
      request_record.update!(status: :converted, ticket: ticket)
      sign_in(owner)

      expect do
        post member_helpdesk_request_conversion_path(request_record), params: { title: "Again", description: "Again" }
      end.not_to change(Ticketing::Ticket, :count)

      expect(response).to redirect_to(member_helpdesk_request_path(request_record))
    end

    it "refuses who has no key" do
      sign_in(colleague)

      get new_member_helpdesk_request_conversion_path(request_record)
      expect(response).to redirect_to(root_path)

      expect do
        post member_helpdesk_request_conversion_path(request_record), params: { title: "T", description: "D" }
      end.not_to change(Ticketing::Ticket, :count)
    end
  end

  describe "joining a ticket that exists" do
    let!(:ticket) { create(:ticket, project: project, title: "Card payments are down") }

    it "links the request and undoes it" do
      sign_in(owner)

      post member_helpdesk_request_ticket_link_path(request_record), params: { ticket_id: ticket.id }
      expect(response).to redirect_to(member_helpdesk_request_path(request_record))
      expect(request_record.reload).to have_attributes(status: "linked", ticket: ticket)

      delete member_helpdesk_request_ticket_link_path(request_record)
      expect(request_record.reload).to have_attributes(status: "received", ticket: nil)
    end

    it "refuses a ticket of another project" do
      other = create(:ticket, project: create(:project, organization: org))
      sign_in(owner)

      post member_helpdesk_request_ticket_link_path(request_record), params: { ticket_id: other.id }

      expect(request_record.reload).to be_status_received
      expect(flash[:alert]).to be_present
    end

    it "keeps a converted request as it is on undo" do
      request_record.update!(status: :converted, ticket: ticket)
      sign_in(owner)

      delete member_helpdesk_request_ticket_link_path(request_record)

      expect(request_record.reload).to have_attributes(status: "converted", ticket: ticket)
    end

    it "refuses who has no key" do
      sign_in(colleague)

      post member_helpdesk_request_ticket_link_path(request_record), params: { ticket_id: ticket.id }

      expect(request_record.reload).to be_status_received
    end

    it "offers the tickets of the request's project on the request page" do
      create(:ticket, project: create(:project, organization: org), title: "Elsewhere 7781")
      sign_in(owner)

      get member_helpdesk_request_path(request_record)

      expect(response.body).to include("Card payments are down", "helpdesk-convert", "helpdesk-link-form")
      expect(response.body).not_to include("Elsewhere 7781")
    end

    it "narrows the ticket search to the request's project" do
      create(:ticket, project: create(:project, organization: org), title: "Card elsewhere 7782")
      sign_in(owner)

      get linkable_member_tickets_path(q: "Card", project_id: project.id)

      labels = response.parsed_body["data"].map { |row| row["label"] }
      expect(labels).to contain_exactly("#{ticket.code} · Card payments are down")
    end
  end

  describe "the request page once handled" do
    it "shows the ticket and no way to convert again" do
      ticket = create(:ticket, project: project, title: "Card payments are down")
      request_record.update!(status: :linked, ticket: ticket)
      sign_in(owner)

      get member_helpdesk_request_path(request_record)

      expect(response.body).to include("Card payments are down", "helpdesk-unlink")
      expect(response.body).not_to include("helpdesk-convert", "helpdesk-discard")
    end

    it "says so when the ticket was deleted" do
      request_record.update!(status: :converted)
      sign_in(owner)

      get member_helpdesk_request_path(request_record)

      expect(response.body).to include("helpdesk-ticket-gone")
    end

    it "renders in Italian" do
      owner.update!(locale: "it")
      sign_in(owner)

      get member_helpdesk_request_path(request_record)
      expect(response.body).to include("Trasforma in ticket", "Collega")

      get new_member_helpdesk_request_conversion_path(request_record)
      expect(response.body).to include("Crea il ticket")
    end
  end

  describe "errors of the same visit (CYRA-942)" do
    it "shows the errors that carry the visit id of the request, one click away" do
      request_record.update!(session_id: "visit4411")
      group = create(:error_group, project: project, title: "TypeError: card is undefined")
      create(:error_event, group: group, project: project, replay_session_id: "visit4411")
      other = create(:error_group, project: project, title: "RangeError: elsewhere 7791")
      create(:error_event, group: other, project: project, replay_session_id: "another-visit")
      sign_in(owner)

      get member_helpdesk_request_path(request_record)

      expect(response.body).to include("Errors in the same visit", "TypeError: card is undefined",
                                       member_monitoring_error_group_path(group))
      expect(response.body).not_to include("RangeError: elsewhere 7791")
    end

    it "shows nothing when the request has no visit id" do
      request_record.update!(session_id: nil)
      sign_in(owner)

      get member_helpdesk_request_path(request_record)

      expect(response.body).not_to include("helpdesk-visit-errors")
    end
  end

  describe "the ticket page" do
    let(:ticket) { create(:ticket, project: project) }

    before do
      request_record.update!(status: :converted, ticket: ticket)
      create(:helpdesk_request, project: project, body: "Same here 5522", status: :linked, ticket: ticket)
    end

    it "shows how many requests stand behind the ticket, without addresses" do
      sign_in(owner)

      get member_ticket_path(ticket)

      expect(response.body).to include("2 help desk requests", "I cannot pay by card 4411.", "Same here 5522")
      expect(response.body).not_to include("anna@example.com")
    end

    it "hides them from who has no help desk key" do
      sign_in(colleague)

      get member_ticket_path(ticket)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("ticket-helpdesk-requests", "Same here 5522")
    end
  end
end
