# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Analytics (stats API bearer)", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, analytics_enabled: true) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:secret) do
    Projects::Tokens::Issue.call(project:, name: "CI", host: "bugs.example.com", environment:).value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  before { create_list(:pageview, 2, project:, path: "/home") }

  it "200 con envelope data e le sezioni dello snapshot" do
    get "/api/v1/projects/#{project.id}/analytics", headers: headers

    expect(response).to have_http_status(:ok)
    data = response.parsed_body["data"]
    expect(data.keys).to include("summary", "timeseries", "top_pages", "channels", "breakdowns", "goals")
    expect(data.dig("summary", "pageviews")).to eq(2)
    expect(data.dig("summary", "visitors")).to eq(2)
  end

  it "timeseries del wire: ogni bucket espone solo pageviews e visitors (contratto congelato, niente :at interno)" do
    get "/api/v1/projects/#{project.id}/analytics", headers: headers

    bucket = response.parsed_body.dig("data", "timeseries").first
    expect(bucket.keys).to contain_exactly("pageviews", "visitors")
  end

  it "include le conversioni dei goal" do
    create(:analytics_goal, project:, path_pattern: "/home", display_name: "Home")
    get "/api/v1/projects/#{project.id}/analytics", headers: headers

    goal = response.parsed_body.dig("data", "goals").first
    expect(goal["display_name"]).to eq("Home")
    expect(goal.dig("conversions", "unique_conversions")).to be >= 1
  end

  it "filtra via query param (allowlist)" do
    create(:pageview, project:, path: "/other", browser: "Firefox")
    get "/api/v1/projects/#{project.id}/analytics", params: { browser: "Chrome" }, headers: headers

    expect(response.parsed_body.dig("data", "summary", "pageviews")).to eq(2) # factory browser Chrome; Firefox escluso
  end

  it "senza bearer → 401" do
    get "/api/v1/projects/#{project.id}/analytics"
    expect(response).to have_http_status(:unauthorized)
  end

  it "BOLA: project_id del path ≠ progetto del token → 404 R404-ANALYTICS-001" do
    other = create(:project, organization:)
    get "/api/v1/projects/#{other.id}/analytics", headers: headers

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("R404-ANALYTICS-001")
  end
end
