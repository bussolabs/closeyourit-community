# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::MetricGroups (lettura)", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:secret) do
    Projects::Tokens::Issue.call(project:, name: "CI", host: "bugs.example.com", environment:).value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "index → 200 { data: [...] } con i gruppi del progetto" do
    group = create(:metric_group, project:)
    get "/api/v1/metric_groups", headers: headers
    expect(response).to have_http_status(:ok)
    ids = response.parsed_body["data"].map { |g| g["id"] }
    expect(ids).to include(group.id)
  end

  it "index filtra per kind" do
    slow_query = create(:metric_group, project:, kind: :slow_query)
    slow_method = create(:metric_group, project:, kind: :slow_method)
    get "/api/v1/metric_groups", params: { kind: "slow_method" }, headers: headers
    ids = response.parsed_body["data"].map { |g| g["id"] }
    expect(ids).to include(slow_method.id)
    expect(ids).not_to include(slow_query.id)
  end

  it "index pagina (default 10) e ritorna meta invece di serializzare tutto" do
    create_list(:metric_group, 12, project:)
    get "/api/v1/metric_groups", headers: headers
    expect(response.parsed_body["data"].length).to eq(10)
    expect(response.parsed_body["meta"]).to include("total" => 12, "total_pages" => 2)
    get "/api/v1/metric_groups", params: { page: 2 }, headers: headers
    expect(response.parsed_body["data"].length).to eq(2)
  end

  it "show → 200 con aggregati di durata (avg, max)" do
    group = create(:metric_group, project:, samples_count: 2,
                                  duration_total_ms: 300.0, duration_min_ms: 100.0, duration_max_ms: 200.0)
    get "/api/v1/metric_groups/#{group.id}", headers: headers
    expect(response).to have_http_status(:ok)
    data = response.parsed_body["data"]
    expect(data["duration_avg_ms"]).to eq(150.0)
    expect(data["duration_max_ms"]).to eq(200.0)
  end

  it "BOLA: gruppo di un altro progetto → 404" do
    other = create(:project, organization:)
    foreign = create(:metric_group, project: other)
    get "/api/v1/metric_groups/#{foreign.id}", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "senza bearer → 401" do
    get "/api/v1/metric_groups", headers: {}
    expect(response).to have_http_status(:unauthorized)
  end
end
