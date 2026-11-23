# frozen_string_literal: true

require "rails_helper"

# CYRA-1352 — moving a ticket from the command line, and what its old code answers afterwards.
RSpec.describe "Cli::V1::Tickets::Moves", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:site) { create(:project, organization:, key: "LBWB") }
  let!(:office) { create(:project, organization:, key: "LBRA") }
  let(:ticket) { create(:ticket, project: site, organization:) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  before { create(:membership, account:, organization:, role: :owner) }

  def move(target)
    post "/cli/v1/projects/#{site.id}/tickets/#{ticket.code}/move", headers:, params: { target_project: target }
  end

  it "moves the ticket to the project named by its key and answers with the new code" do
    move("lbra")

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "code")).to start_with("LBRA-")
    expect(ticket.reload.project).to eq(office)
  end

  it "the old code answers 404 with the code the ticket has now" do
    old_code = ticket.code
    move(office.id)

    get "/cli/v1/projects/#{site.id}/tickets/#{old_code}", headers: headers

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-TICKET-031")
    expect(response.parsed_body.dig("error", "details", "code")).to eq(ticket.reload.code)
  end

  it "an unknown number of the project stays a plain 404" do
    get "/cli/v1/projects/#{site.id}/tickets/LBWB-999", headers: headers

    expect(response.parsed_body.dig("error", "code")).to eq("R404-SYSTEM-001")
  end

  it "a project the caller cannot see is not found" do
    move(create(:project).id)

    expect(response).to have_http_status(:not_found)
    expect(ticket.reload.project).to eq(site)
  end

  it "needs tickets.edit on the target project too" do
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project: site)
    create(:project_membership, account: member, project: office)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

    post "/cli/v1/projects/#{site.id}/tickets/#{ticket.code}/move",
         headers: { "Authorization" => "Bearer #{member_secret}" }, params: { target_project: "LBRA" }

    expect(response).to have_http_status(:forbidden)
    expect(ticket.reload.project).to eq(site)
  end

  it "passes on the reason when the move is refused" do
    ticket.create_agent_workflow!(triage_requested_at: Time.current)

    move("LBRA")

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-TICKET-027")
  end
end
