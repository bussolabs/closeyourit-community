# frozen_string_literal: true

require "rails_helper"

# CYRA-1086 — the project owner (the client) is the default reporter of tickets typed in by hand.
RSpec.describe "Member ticket reporter", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:status) { create(:ticket_status, organization: org) }
  let(:priority) { create(:ticket_priority, organization: org) }
  let(:admin) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :owner) } }
  let(:client) { linked_member }

  def linked_member
    create(:account).tap do |account|
      create(:membership, account: account, organization: org, role: :member)
      create(:project_membership, account: account, project: project)
    end
  end

  def unlinked_member
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def ticket_params(extra = {})
    { project_id: project.id, title: "Cart empties on login", description: "Sent by email",
      status_id: status.id, priority_id: priority.id }.merge(extra)
  end

  before { sign_in(admin) }

  describe "project settings" do
    it "saves a person who sees the project as owner" do
      patch member_project_settings_path(project), params: { owner_id: client.id }

      expect(project.reload.owner).to eq(client)
    end

    it "refuses a person who does not see the project" do
      patch member_project_settings_path(project), params: { owner_id: unlinked_member.id }

      expect(response).to have_http_status(:unprocessable_content)
      expect(project.reload.owner).to be_nil
    end

    it "offers only the people who see the project" do
      client
      outsider = unlinked_member

      get member_project_settings_path(project)

      field = Nokogiri::HTML(response.body).at_css("select#owner_id")
      values = field.css("option").map { |option| option["value"] }
      expect(values).to include(client.id)
      expect(values).not_to include(outsider.id)
    end
  end

  describe "new ticket" do
    before { project.update!(owner: client) }

    it "names the project owner as reporter when the form leaves it automatic" do
      post member_tickets_path, params: ticket_params(reporter_id: "")

      ticket = Ticketing::Ticket.last
      expect(ticket.reporter).to eq(client)
      expect(ticket.reviewer).to eq(admin)
    end

    it "names the reporter picked in the form" do
      post member_tickets_path, params: ticket_params(reporter_id: admin.id)

      expect(Ticketing::Ticket.last.reporter).to eq(admin)
    end

    it "pre-fills the reporter with the owner of the project the form opens from" do
      get new_member_ticket_path(project_id: project.id)

      selected = Nokogiri::HTML(response.body).at_css("select#reporter_id option[selected]")
      expect(selected["value"]).to eq(client.id)
    end
  end

  describe "PATCH reporter" do
    let(:ticket) { create(:ticket, organization: org, project: project, reporter: admin) }

    it "names another reporter and writes it in the history" do
      patch reporter_member_ticket_path(ticket), params: { reporter_id: client.id }

      expect(ticket.reload.reporter).to eq(client)
      follow_redirect!
      expect(flash[:notice]).to eq(I18n.t("member.tickets.reporter_changed"))
    end

    it "refuses a person who does not see the project" do
      patch reporter_member_ticket_path(ticket), params: { reporter_id: unlinked_member.id }

      expect(ticket.reload.reporter).to eq(admin)
      expect(flash[:alert]).to eq(I18n.t("member.tickets.errors.reporter_not_allowed"))
    end

    it "shows the reporter picker on the ticket page" do
      client

      get member_ticket_path(ticket)

      expect(response.body).to include("ticket-reporter-#{client.id}")
    end
  end
end
