# frozen_string_literal: true

require "rails_helper"

RSpec.describe "OTLP trace persistence", type: :request do
  let(:project) { create(:project) }
  let(:environment) { create(:environment, organization: project.organization).tap { |item| project.environments << item } }
  let(:credential) { Projects::Tokens::Issue.call(project:, environment:, host: "localhost", name: "Traces", scopes: %w[ingest read]).value }
  let(:headers) { { "Authorization" => "Bearer #{credential[:secret]}", "Content-Type" => "application/json" } }
  let(:path) { "/api/v1/projects/#{project.id}/otlp/traces" }
  let(:span) { { traceId: "a" * 32, spanId: "b" * 16, name: "checkout", startTimeUnixNano: "1780000000123456789", endTimeUnixNano: "1780000000123456799" } }
  let(:payload) { { resourceSpans: [ { scopeSpans: [ { spans: [ span ] } ] } ] } }

  it "persists before acknowledging and exposes exact timestamps through private paginated reads" do
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq({})
    get "/api/v1/traces/#{span[:traceId]}/spans", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").sole).to include("start_time_unix_nano" => span[:startTimeUnixNano], "api_schema_version" => 1)
    expect(response.parsed_body.dig("meta", "total")).to eq(1)
  end

  it "returns partial success for invalid IDs without creating empty traces" do
    span[:spanId] = "0" * 16
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("partialSuccess", "rejectedSpans")).to eq("1")
    expect(project.traces.count).to eq(0)
  end

  it "rejects malformed JSON and oversized bodies before parameter parsing" do
    post path, params: "{", headers: headers
    expect(response).to have_http_status(:bad_request)
    post path, params: "x" * (5 * 1024 * 1024 + 1), headers: headers
    expect(response).to have_http_status(:content_too_large)
  end

  it "rejects unsupported content types and compressed backend bodies" do
    post path, params: payload.to_json, headers: headers.merge("Content-Type" => "text/plain")
    expect(response).to have_http_status(:unsupported_media_type)
    post path, params: payload.to_json, headers: headers.merge("Content-Encoding" => "gzip")
    expect(response).to have_http_status(:unsupported_media_type)
  end

  it "reads a JSON request once with a bounded limit before any framework parameter parsing" do
    reads = []
    input = StringIO.new("x" * (5 * 1024 * 1024 + 20))
    input.define_singleton_method(:read) do |*arguments|
      reads << arguments.first
      super(*arguments)
    end
    env = Rack::MockRequest.env_for(path, method: "POST", input: input,
      "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => headers.fetch("Authorization"))
    status, _response_headers, response_body = Rails.application.call(env)
    response_body.close if response_body.respond_to?(:close)
    expect(status).to eq(413)
    expect(reads).to eq([ 5 * 1024 * 1024 + 1 ])
    expect(project.trace_spans.count).to eq(0)
  end

  it "reports a retryable storage failure without leaking diagnostics or acknowledging persistence" do
    allow(Traces::Ingest::Record).to receive(:call).and_raise(ActiveRecord::RecordNotFound, "private database details")
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq("message" => "Trace storage is temporarily unavailable")
  end

  it "isolates writes and reads from other projects" do
    other = create(:project)
    post "/api/v1/projects/#{other.id}/otlp/traces", params: payload.to_json, headers: headers
    expect(response).to have_http_status(:not_found)
    Traces::Ingest::Record.call(project: other, payload: JSON.parse(payload.to_json))
    get "/api/v1/traces/#{span[:traceId]}", headers: headers
    expect(response).to have_http_status(:not_found)
    get "/api/v1/traces", headers: headers
    expect(response.parsed_body.fetch("data")).to eq([])
  end

  it "requires ingest for writes and read for private retrieval" do
    credential[:token].update!(scopes: [ "read" ])
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:forbidden)
    credential[:token].update!(scopes: [ "ingest" ])
    get "/api/v1/traces", headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it "lists multiple traces with topology without loading spans or querying once per trace" do
    # Separate setup admissions are not one HTTP request.
    allow_n_plus_one do
      3.times do |index|
      item = JSON.parse(payload.to_json)
      item["resourceSpans"][0]["scopeSpans"][0]["spans"][0]["traceId"] = (index + 1).to_s * 32
      Traces::Ingest::Record.call(project: project, payload: item)
    end
    end
    statements = []
    subscriber = ->(_name, _start, _finish, _id, data) { statements << data[:sql] if data[:sql].include?("traces_spans") }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      get "/api/v1/traces?per=2", headers: headers
    end
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").size).to eq(2)
    expect(response.parsed_body.dig("meta", "total")).to eq(3)
    expect(response.parsed_body.fetch("data").pluck("topology")).to all(include("root_present" => true))
    expect(statements.size).to eq(1)
  end
end
