# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::MetricGroups", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "index → 200 con i gruppi del progetto e meta" do
    group = create(:metric_group, project:)
    get "/cli/v1/projects/#{project.id}/metric_groups", headers: headers

    expect(response).to have_http_status(:ok)
    ids = response.parsed_body["data"].map { |g| g["id"] }
    expect(ids).to include(group.id)
    expect(response.parsed_body["meta"]).to include("total")
  end

  it "index filtra per kind" do
    sq = create(:metric_group, project:, kind: :slow_query)
    sm = create(:metric_group, project:, kind: :slow_method)
    get "/cli/v1/projects/#{project.id}/metric_groups", params: { kind: "slow_method" }, headers: headers

    ids = response.parsed_body["data"].map { |g| g["id"] }
    expect(ids).to include(sm.id)
    expect(ids).not_to include(sq.id)
  end

  it "show → 200" do
    group = create(:metric_group, project:)
    get "/cli/v1/projects/#{project.id}/metric_groups/#{group.id}", headers: headers
    expect(response.parsed_body["data"]["id"]).to eq(group.id)
  end

  it "gruppo di un'altra org → 404 (anti-BOLA)" do
    other = create(:metric_group)
    get "/cli/v1/projects/#{other.project_id}/metric_groups/#{other.id}", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "senza bearer → 401" do
    get "/cli/v1/projects/#{project.id}/metric_groups"
    expect(response).to have_http_status(:unauthorized)
  end
end
