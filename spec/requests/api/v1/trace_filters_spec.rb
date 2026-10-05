# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Private trace filters", type: :request do
  let(:project) { create(:project) }
  let(:environment) { create(:environment, organization: project.organization).tap { |item| project.environments << item } }
  let(:credential) { Projects::Tokens::Issue.call(project: project, environment: environment, host: "localhost", name: "Read traces", scopes: %w[read]).value }
  let(:headers) { { "Authorization" => "Bearer #{credential[:secret]}" } }

  it "preserves the existing default pagination and response for unfiltered clients" do
    Traces::Trace.insert_all!(11.times.map { |i| { project_id: project.id, trace_id: (i + 1).to_s(16).rjust(32, "0"), first_received_at: 40.days.ago, last_received_at: 40.days.ago } })
    get "/api/v1/traces", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("meta")).to include("total" => 11, "per" => 10)
    expect(response.parsed_body.fetch("data").size).to eq(10)
    expect(response.parsed_body.fetch("data").first.keys).to contain_exactly("trace_id", "first_received_at", "last_received_at", "retained_spans_count", "expired_spans_count", "api_schema_version", "topology")
  end

  it "applies explicitly requested status filters inside the authenticated project" do
    own = project.traces.create!(trace_id: "a" * 32, first_received_at: Time.current, last_received_at: Time.current)
    other = create(:project)
    other.traces.create!(trace_id: "b" * 32, first_received_at: Time.current, last_received_at: Time.current)
    get "/api/v1/traces", headers: headers, params: { status: "unknown", q: "" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").map { |row| row.fetch("trace_id") }).to eq([ own.trace_id ])
    expect(response.parsed_body.fetch("meta").fetch("per")).to eq(10)
  end

  it "rejects malformed filters with a small JSON response" do
    get "/api/v1/traces", headers: headers, params: { service: [ "invalid" ] }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-TRACE-001")
    expect(response.body.bytesize).to be < 1024
  end
end
