# frozen_string_literal: true

require "rails_helper"

# CYRA-1309 — the history modal opens each edit on what it replaced, for whoever may read the audit.
RSpec.describe "Member ticket history changes", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project) }
  let!(:edit) do
    create(:ticket_event, ticket: ticket, action: "updated",
                          data: { "description" => [ "Line kept\nOld line", "Line kept\nNew line" ] })
  end

  def account_with(role)
    create(:account).tap do |account|
      create(:membership, account: account, organization: org, role: role)
      create(:project_membership, account: account, project: project)
    end
  end

  def open_history(as:)
    post login_path, params: { email: as.email, password: "Secret123!" }
    get member_ticket_path(ticket, section: "history"), headers: { "Turbo-Frame" => "ticket-history" }
  end

  def changes = Nokogiri::HTML(response.body).at_css("[data-test='member-ticket-event-changes-#{edit.id}']")

  it "shows the removed and added lines of an edit to the owner" do
    open_history(as: account_with(:owner))

    expect(response).to have_http_status(:ok)
    expect(changes).to be_present
    expect(changes.css("[data-test='ticket-event-change-removed']").map(&:text).join).to include("Old line")
    expect(changes.css("[data-test='ticket-event-change-added']").map(&:text).join).to include("New line")
    expect(changes.text).not_to include("Line kept")
  end

  it "keeps the changes out of reach without tickets.audit.view" do
    open_history(as: account_with(:member))

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("member-ticket-event-#{edit.id}")
    expect(changes).to be_nil
  end
end
