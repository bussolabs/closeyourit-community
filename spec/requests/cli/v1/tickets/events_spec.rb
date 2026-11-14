# frozen_string_literal: true

require "rails_helper"

# CYRA-1309 — a ticket's history over the CLI, with the full before/after of every edit,
# behind the same tickets.audit.view key as the other audit material.
RSpec.describe "Cli::V1::Tickets::Events", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, project:, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{member_secret}" }
  end

  def events_path(target = ticket) = "/cli/v1/projects/#{project.id}/tickets/#{target.id}/events"

  it "rejects a request without a bearer token" do
    get events_path

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns the events newest first, with actor and the full before/after" do
    long_text = "Old description. #{"x" * 5_000}"
    older = create(:ticket_event, ticket:, created_at: 2.hours.ago)
    newer = create(:ticket_event, ticket:, action: "updated", created_at: 1.hour.ago,
                                  data: { "description" => [ long_text, "New description" ] })

    get events_path, headers: headers

    expect(response).to have_http_status(:ok)
    data = response.parsed_body["data"]
    expect(data.map { |event| event["id"] }).to eq([ newer.id, older.id ])
    expect(data.first).to include("action" => "updated", "actor_name" => newer.actor_name, "impersonated" => false)
    expect(data.first["created_at"]).to be_present
    expect(data.first["data"]["description"]).to eq([ long_text, "New description" ])
    expect(response.parsed_body["meta"]).to include("page" => 1, "total" => 2)
  end

  it "accepts the ticket code instead of the id" do
    create(:ticket_event, ticket:)

    get "/cli/v1/projects/#{project.id}/tickets/#{ticket.code}/events", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"].size).to eq(1)
  end

  it "refuses a member who sees the project but lacks tickets.audit.view" do
    get events_path, headers: member_headers

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
  end

  it "hides a ticket of another organization" do
    other_ticket = create(:ticket, organization: create(:organization))

    get events_path(other_ticket), headers: headers

    expect(response).to have_http_status(:not_found)
  end
end
