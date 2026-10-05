# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets::Github", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:) }
  let!(:repository) do
    create(:github_repository, project:, installation: create(:github_installation, organization:))
  end

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  def branch_path = "/cli/v1/projects/#{project.id}/tickets/#{ticket.code}/github/branch"
  def pr_path = "/cli/v1/projects/#{project.id}/tickets/#{ticket.code}/github/pull_request"

  it "senza bearer → 401" do
    post branch_path
    expect(response).to have_http_status(:unauthorized)
  end

  it "POST branch → crea il branch (envelope data)" do
    client = instance_double(Github::Client, ref: { "object" => { "sha" => "abc" } }, create_ref: {})
    allow(Github::Client).to receive(:new).and_return(client)

    post branch_path, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"]["kind"]).to eq("branch")
    expect(ticket.github_branches).to exist
  end

  it "POST pull_request con branch → apre la PR" do
    create(:github_branch, repository:, ticket:, name: "#{ticket.code}-fix")
    client = instance_double(Github::Client, create_pull: {
                               "number" => 9, "html_url" => "https://github.com/bussolabs/app/pull/9",
                               "id" => 2, "user" => { "login" => "bot" }
                             })
    allow(Github::Client).to receive(:new).and_return(client)

    post pr_path, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"]["number"]).to eq(9)
  end

  it "POST pull_request senza branch → 422 R422-GITHUB-005" do
    post pr_path, headers: headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-GITHUB-005")
  end

  it "ticket di un'altra org → 404 (anti-BOLA)" do
    other_project = create(:project)
    other_ticket = create(:ticket, organization: other_project.organization, project: other_project)

    post "/cli/v1/projects/#{other_project.id}/tickets/#{other_ticket.code}/github/branch", headers: headers

    expect(response).to have_http_status(:not_found)
  end
end
