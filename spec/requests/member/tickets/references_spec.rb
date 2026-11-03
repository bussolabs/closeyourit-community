# frozen_string_literal: true

require "rails_helper"

# CYRA-1148 — the endpoint that turns ticket codes found in rendered text into labels. Only the
# tickets the reader can see come back: a code of a hidden project stays plain text in the page.
RSpec.describe "Member::Tickets::References", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization: org, key: "SEEN") }
  let(:hidden_project) { create(:project, organization: org, key: "HIDE") }
  let(:team) { create(:team, organization: org) }

  before do
    create(:membership, account: account, organization: org, role: :member)
    create(:team_membership, team: team, account: account)
    create(:team_project_access, team: team, project: project)
  end

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  def labels
    response.parsed_body["data"]
  end

  it "redirects to login when signed out" do
    get references_member_tickets_path, params: { codes: "SEEN-1" }

    expect(response).to redirect_to(login_path)
  end

  it "returns a label with code, title, status and link for a visible ticket" do
    sign_in(account)
    ticket = create(:ticket, organization: org, project:, title: "Checkout is slow")

    get references_member_tickets_path, params: { codes: ticket.code }

    expect(response).to have_http_status(:ok)
    label = Nokogiri::HTML5.fragment(labels.fetch(ticket.code))
    expect(label.at_css("a[data-test='ticket-ref']")["href"]).to eq(member_ticket_path(ticket))
    expect(label.text).to include(ticket.code, "Checkout is slow", ticket.status.display_label)
  end

  it "leaves out tickets of projects the reader cannot see" do
    sign_in(account)
    hidden = create(:ticket, organization: org, project: hidden_project, title: "Secret plan")

    get references_member_tickets_path, params: { codes: hidden.code }

    expect(labels).to eq({})
    expect(response.body).not_to include("Secret plan")
  end

  it "leaves out tickets of another organization" do
    sign_in(account)
    foreign = create(:ticket, organization: create(:organization), title: "Elsewhere")

    get references_member_tickets_path, params: { codes: foreign.code }

    expect(labels).to eq({})
  end

  it "ignores codes that match no ticket and text that is not a code" do
    sign_in(account)

    get references_member_tickets_path, params: { codes: "SEEN-999,ISO-8601,<b>,," }

    expect(response).to have_http_status(:ok)
    expect(labels).to eq({})
  end

  it "resolves many codes with a single ticket query" do
    sign_in(account)
    tickets = allow_n_plus_one { create_list(:ticket, 3, organization: org, project:) }

    queries = captured_sql { get references_member_tickets_path, params: { codes: tickets.map(&:code).join(",") } }

    expect(labels.keys).to match_array(tickets.map(&:code))
    expect(queries.grep(/FROM "ticketing_tickets"/).size).to eq(1)
  end

  it "reads at most LIMIT codes" do
    sign_in(account)
    ticket = create(:ticket, organization: org, project:)
    filler = (1..Member::Tickets::ReferencesController::LIMIT).map { |n| "NONE-#{n}" }

    get references_member_tickets_path, params: { codes: (filler + [ ticket.code ]).join(",") }

    expect(labels).to eq({})
  end
end
