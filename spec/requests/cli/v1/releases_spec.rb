# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Releases", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    get "/cli/v1/projects/#{project.id}/releases"
    expect(response).to have_http_status(:unauthorized)
  end

  it "index → 200 con le release del progetto e meta di paginazione" do
    r1 = create(:release, project:, version: "v1.0.0")
    r2 = create(:release, project:, version: "v1.1.0")

    get "/cli/v1/projects/#{project.id}/releases", headers: headers

    expect(response).to have_http_status(:ok)
    versions = response.parsed_body["data"].map { |r| r["version"] }
    expect(versions).to include("v1.0.0", "v1.1.0")
    expect(response.parsed_body["data"].map { |r| r["id"] }).to include(r1.id, r2.id)
    expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
  end

  # The web lists moved to 12 rows per page; the machine contract keeps its own default of 10.
  it "keeps 10 as the default page size of the machine contract" do
    get "/cli/v1/projects/#{project.id}/releases", headers: headers

    expect(response.parsed_body.dig("meta", "per")).to eq(10)
  end

  it "index NON include le release di un altro progetto" do
    mine = create(:release, project:)
    other = create(:release, project: create(:project, organization:))

    get "/cli/v1/projects/#{project.id}/releases", headers: headers

    ids = response.parsed_body["data"].map { |r| r["id"] }
    expect(ids).to include(mine.id)
    expect(ids).not_to include(other.id)
  end

  it "progetto di un'altra org → 404 (anti-BOLA)" do
    other = create(:project)

    get "/cli/v1/projects/#{other.id}/releases", headers: headers
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body["error"]["code"]).to eq("R404-SYSTEM-001")
  end

  it "member senza assegnazione non vede il progetto → 404 (strict)" do
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    member_headers = { "Authorization" => "Bearer #{Accounts::ApiTokens::Issue.call(account: member, organization:, name: 'CLI').value[:secret]}" }

    get "/cli/v1/projects/#{project.id}/releases", headers: member_headers
    expect(response).to have_http_status(:not_found)
  end
end
