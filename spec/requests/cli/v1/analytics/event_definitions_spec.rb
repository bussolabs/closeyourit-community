# frozen_string_literal: true

require "rails_helper"

# CYRA-1158 — the declared events of a project, managed from the command line.
RSpec.describe "Cli::V1::Analytics event definitions", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) do
    create(:project, organization:, analytics_enabled: true).tap do |p|
      p.project_platforms.create!(platform: create(:platform, organization:, supports_analytics: true))
    end
  end
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  before { create(:membership, account:, organization:, role: :owner) }

  def events_path(proj = project) = "/cli/v1/projects/#{proj.id}/analytics/events"

  it "lists, creates, updates and deletes declared events" do
    post events_path, headers:, params: { name: "Signup", property_names: %w[plan seats] }
    expect(response).to have_http_status(:created)
    id = response.parsed_body["data"]["id"]
    expect(response.parsed_body["data"]).to include("name" => "Signup", "property_names" => %w[plan seats])

    patch "#{events_path}/#{id}", headers:, params: { property_names: %w[coupon] }
    expect(response.parsed_body["data"]).to include("name" => "Signup", "property_names" => %w[coupon])

    get events_path, headers: headers
    expect(response.parsed_body["data"].map { _1["name"] }).to eq([ "Signup" ])

    delete "#{events_path}/#{id}", headers: headers
    expect(response).to have_http_status(:no_content)
    expect(project.analytics_event_definitions).to be_empty
  end

  it "answers 422 on a duplicate name" do
    create(:analytics_event_definition, project:, name: "Signup")

    post events_path, headers:, params: { name: "Signup" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]["code"]).to eq("R422-EVENTDEF-001")
  end

  it "answers 404 for a project the account cannot see" do
    foreign = create(:project, analytics_enabled: true)
    create(:analytics_event_definition, project: foreign)

    get events_path(foreign), headers: headers
    expect(response).to have_http_status(:not_found)
  end
end
