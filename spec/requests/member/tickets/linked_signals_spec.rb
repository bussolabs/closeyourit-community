# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets linked signals", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:status) { create(:ticket_status, organization: org) }
  let(:priority) { create(:ticket_priority, organization: org) }
  let(:owner) { create(:account).tap { |account| create(:membership, account: account, organization: org, role: :owner) } }
  let!(:error_group) { create(:error_group, project: project, title: "NoMethodError in Checkout") }
  let!(:metric_group) { create(:metric_group, :slow_method, project: project) }

  before { post login_path, params: { email: owner.email, password: "Secret123!" } }

  def create_params(extra = {})
    { project_id: project.id, title: "Checkout broken", description: "It breaks.", kind: "bug",
      status_id: status.id, priority_id: priority.id }.merge(extra)
  end

  describe "GET new" do
    it "offers the open errors and slow operations of the project" do
      get new_member_ticket_path(project_id: project.id)

      page = Nokogiri::HTML(response.body)
      signals = page.at_css("[data-test='ticket-signals']")
      expect(signals.at_css("select[name='error_group_id']").text).to include("NoMethodError in Checkout")
      expect(signals.at_css("select[name='metric_group_id']").text).to include("Checkout#total")
    end

    it "leaves out what is resolved or already has a ticket" do
      create(:error_group, :resolved, project: project, title: "Resolved one")
      create(:error_group, project: project, title: "Promoted one",
             ticket: create(:ticket, organization: org, project: project))

      get new_member_ticket_path(project_id: project.id)

      options = Nokogiri::HTML(response.body).at_css("select[name='error_group_id']").text
      expect(options).not_to include("Resolved one")
      expect(options).not_to include("Promoted one")
    end

    it "shows the block only while the type is bug" do
      get new_member_ticket_path(project_id: project.id)

      signals = Nokogiri::HTML(response.body).at_css("[data-test='ticket-signals']")
      expect(signals["class"]).to include("hidden")
      expect(signals["class"]).to include("group-has-[input[name=kind][value=bug]:checked]/ticket:block")
    end

    it "does not offer signals to someone who may not promote them" do
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      create(:project_membership, account: member, project: project)
      delete logout_path
      post login_path, params: { email: member.email, password: "Secret123!" }

      get new_member_ticket_path(project_id: project.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("ticket-signals")
    end

    it "does not offer the block when editing" do
      ticket = create(:ticket, organization: org, project: project)

      get edit_member_ticket_path(ticket)

      expect(response.body).not_to include("ticket-signals")
    end
  end

  describe "POST create" do
    it "links the chosen error and slow operation to the new bug" do
      post member_tickets_path, params: create_params(error_group_id: error_group.id, metric_group_id: metric_group.id)

      ticket = Ticketing::Ticket.find_by!(title: "Checkout broken")
      expect(error_group.reload.ticket).to eq(ticket)
      expect(metric_group.reload.ticket).to eq(ticket)
    end

    it "still links them when the ticket is created from the duplicate comparison" do
      post member_tickets_path, params: create_params(error_group_id: error_group.id, metric_group_id: metric_group.id,
                                                      dedup_ack: "create", dedup_reason: "Another endpoint")

      ticket = Ticketing::Ticket.find_by!(title: "Checkout broken")
      expect(error_group.reload.ticket).to eq(ticket)
      expect(metric_group.reload.ticket).to eq(ticket)
    end

    it "shows the linked slow operation on the ticket" do
      post member_tickets_path, params: create_params(metric_group_id: metric_group.id)
      follow_redirect!

      expect(response.body).to include("ticket-performance-origin-link")
    end
  end
end
