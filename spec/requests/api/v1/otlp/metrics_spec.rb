# frozen_string_literal: true

require "rails_helper"

RSpec.describe "OTLP generic metrics", type: :request do
  let(:project) { create(:project) }
  let(:environment) { create(:environment, organization: project.organization).tap { |item| project.environments << item } }
  let(:credential) { Projects::Tokens::Issue.call(project: project, environment: environment, host: "localhost", name: "Measurements", scopes: %w[ingest read]).value }
  let(:headers) { { "Authorization" => "Bearer #{credential[:secret]}", "Content-Type" => "application/json" } }
  let(:path) { "/api/v1/projects/#{project.id}/otlp/metrics" }
  let(:point) { { "startTimeUnixNano" => "1000000000", "timeUnixNano" => "2000000000", "asInt" => "10" } }
  let(:metric) { { "name" => "requests", "sum" => { "aggregationTemporality" => 1, "isMonotonic" => true, "dataPoints" => [ point ] } } }
  let(:payload) { { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ metric ] } ] } ] } }

  it "admits multiple series with bounded SQL and reads points and aggregates privately" do
    payload["resourceMetrics"][0]["scopeMetrics"][0]["metrics"] = 4.times.map { |index| metric.merge("name" => "requests#{index}") }
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq({})
    expect(project.measurement_series.count).to eq(4)
    get "/api/v1/measurement_series?name=requests0", headers: headers
    expect(response).to have_http_status(:ok)
    series = response.parsed_body.fetch("data").sole
    expect(series).to include("name" => "requests0", "temporality" => 1, "monotonic" => true)
    get "/api/v1/measurement_series/#{series['id']}/points", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").sole).to include("time_unix_nano" => "2000000000")
    get "/api/v1/measurement_series/#{series['id']}/aggregation", params: { from: Time.at(1).utc.iso8601, to: Time.at(2).utc.iso8601 }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "buckets").sole).to include("status" => "known", "value" => { "sum" => "10", "rate" => "10" })
  end

  it "reports unsupported summary points through partial success" do
    metric["summary"] = metric.delete("sum")
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("partialSuccess", "rejectedDataPoints")).to eq("1")
    expect(project.measurement_points.count).to eq(0)
  end

  it "enforces the raw body bound before any JSON parameter parsing" do
    reads = []
    input = StringIO.new("x" * (5 * 1024 * 1024 + 20))
    input.define_singleton_method(:read) { |*args| reads << args.first; super(*args) }
    env = Rack::MockRequest.env_for(path, method: "POST", input: input,
      "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => headers.fetch("Authorization"))
    status, _response_headers, body = Rails.application.call(env)
    body.close if body.respond_to?(:close)
    expect(status).to eq(413)
    expect(reads).to eq([ 5 * 1024 * 1024 + 1 ])
  end

  it "rejects cross-project requests and enforces read and ingest scopes" do
    other = create(:project)
    Measurements::Ingest::Record.call(project: other, payload: payload)
    post "/api/v1/projects/#{other.id}/otlp/metrics", params: payload.to_json, headers: headers
    expect(response).to have_http_status(:not_found)
    get "/api/v1/measurement_series/#{other.measurement_series.sole.id}", headers: headers
    expect(response).to have_http_status(:not_found)
    credential[:token].update!(scopes: [ "read" ])
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:forbidden)
    credential[:token].update!(scopes: [ "ingest" ])
    get "/api/v1/measurement_series", headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it "rejects an oversized serialized series instead of returning an unbounded response" do
    metric["name"] = "x" * (1024 * 1024 + 1)
    post path, params: payload.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    get "/api/v1/measurement_series/#{project.measurement_series.sole.id}", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-OTLP-001")
  end

  it "rejects nonexistent calendar dates in aggregation requests" do
    Measurements::Ingest::Record.call(project: project, payload: payload)
    get "/api/v1/measurement_series/#{project.measurement_series.sole.id}/aggregation",
      params: { from: "2026-02-31T12:00:00Z", to: "2026-03-04T12:00:00Z" }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-MEASUREMENT-001")
  end
end
