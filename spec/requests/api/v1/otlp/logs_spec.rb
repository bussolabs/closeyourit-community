# frozen_string_literal: true

require "rails_helper"

RSpec.describe "OTLP log persistence", type: :request do
  let(:project) { create(:project) }
  let(:environment) { create(:environment, organization: project.organization).tap { |item| project.environments << item } }
  let(:credential) { Projects::Tokens::Issue.call(project:, environment:, host: "localhost", name: "Logs", scopes: %w[ingest read]).value }
  let(:headers) { { "Authorization" => "Bearer #{credential[:secret]}", "Content-Type" => "application/json" } }
  let(:path) { "/api/v1/projects/#{project.id}/otlp/logs" }
  let(:log) { { traceId: "a" * 32, spanId: "b" * 16, body: { stringValue: "checkout" }, timeUnixNano: "1780000000123456789" } }
  let(:payload) { { resourceLogs: [ { scopeLogs: [ { logRecords: [ log ] } ] } ] } }

  it "persists before acknowledging and exposes exact timestamps through private paginated reads" do
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq({})
    get "/api/v1/log_entries", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").sole).to include("event_time_unix_nano" => log[:timeUnixNano], "signal_source" => "otlp")
    expect(response.parsed_body.dig("meta", "total")).to eq(1)
  end

  it "returns partial success for invalid IDs without creating empty traces" do
    log[:spanId] = "0" * 16
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("partialSuccess", "rejectedLogRecords")).to eq("1")
    expect(project.logs_entries.count).to eq(0)
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
    expect(project.logs_entries.count).to eq(0)
  end

  it "reports a retryable storage failure without leaking diagnostics or acknowledging persistence" do
    allow(Logs::Otlp::Record).to receive(:call).and_raise(ActiveRecord::RecordNotFound, "private database details")
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq("message" => "Log storage is temporarily unavailable")
  end

  it "isolates writes and reads from other projects" do
    other = create(:project)
    post "/api/v1/projects/#{other.id}/otlp/logs", params: payload.to_json, headers: headers
    expect(response).to have_http_status(:not_found)
    Logs::Otlp::Record.call(project: other, payload: JSON.parse(payload.to_json))
        get "/api/v1/log_entries", headers: headers
    expect(response.parsed_body.fetch("data")).to eq([])
  end

  it "requires ingest for writes and read for private retrieval" do
    credential[:token].update!(scopes: [ "read" ])
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:forbidden)
    credential[:token].update!(scopes: [ "ingest" ])
    get "/api/v1/log_entries", headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it "correlates explicitly linked errors without changing a first Sentry event or crossing project boundaries" do
    event_id = "c" * 32
    original = { "event_id" => event_id, "message" => "Original Sentry without trace" }
    Errors::Ingest::Record.call(project: project, payload: original)
    other = create(:project)
    Errors::Ingest::Record.call(project: other, payload: original)
    traces = { "resourceSpans" => [ { "scopeSpans" => [ { "spans" => [ { "traceId" => "a" * 32, "spanId" => "b" * 16, "name" => "checkout", "startTimeUnixNano" => "1", "endTimeUnixNano" => "2" } ] } ] } ] }
    Traces::Ingest::Record.call(project: project, payload: traces)
    log[:attributes] = [ { key: "closeyourit.error.event_id", value: { stringValue: event_id } } ]
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    get "/api/v1/traces/#{log[:traceId]}/errors", params: { span_id: log[:spanId] }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").sole).to include("event_id" => event_id, "trace_id" => nil)
    expect(project.error_events.sole.payload["message"]).to eq(original["message"])
    get "/api/v1/traces/#{log[:traceId]}/logs", params: { span_id: log[:spanId], per: 1 }, headers: headers
    expect(response.parsed_body.fetch("data").sole["error_event_id"]).to eq(event_id)
    expect(response.parsed_body.dig("meta", "total")).to eq(1)
    get "/api/v1/traces/#{log[:traceId]}/errors", params: { span_id: "f" * 16 }, headers: headers
    expect(response.parsed_body.fetch("data")).to eq([])
    get "/api/v1/traces/#{"d" * 32}/logs", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "bounds serialized and hydrated log responses independently of row count" do
    log[:body] = { stringValue: "x" * (1024 * 1024) }
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    get "/api/v1/log_entries", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-OTLP-001")
    project.logs_entries.delete_all
    Logs::Entry::Bulk.insert_all!([ { project_id: project.id, event_id: "large-retained-row", message: "large", level: 1, data: {}, otlp_payload: { body: "x" * (5 * 1024 * 1024) }, occurred_at: Time.current, created_at: Time.current } ])
    expect(Logs::Entry).not_to receive(:instantiate)
    get "/api/v1/log_entries", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "reports admission lock contention as retryable without a false success" do
    allow(Ingest::EventLock).to receive(:acquire!).and_raise(Ingest::EventLock::Busy)
    log[:eventName] = "exception"
    log[:attributes] = [ { key: "exception.type", value: { stringValue: "TypeError" } } ]
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:service_unavailable)
    expect(project.error_events.count).to eq(0)
  end
end
