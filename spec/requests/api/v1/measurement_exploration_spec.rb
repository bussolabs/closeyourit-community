# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Private measurement exploration", type: :request do
  let(:project) { create(:project) }
  let(:environment) { create(:environment, organization: project.organization).tap { |item| project.environments << item } }
  let(:credential) { Projects::Tokens::Issue.call(project: project, environment: environment, host: "localhost", name: "Measurements", scopes: %w[ingest read]).value }
  let(:headers) { { "Authorization" => "Bearer #{credential[:secret]}" } }

  it "accepts the official camel-case exponential histogram type for quantiles and alert configuration" do
    Measurements::Ingest::Record.call(project: project, payload: { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ {
      "name" => "exponential", "exponentialHistogram" => { "aggregationTemporality" => 1, "dataPoints" => [ {
        "startTimeUnixNano" => "1000000000", "timeUnixNano" => "2000000000", "count" => "2", "scale" => 0, "zeroCount" => "0", "zeroThreshold" => 0,
        "positive" => { "offset" => 0, "bucketCounts" => [ "2" ] }, "negative" => { "offset" => 0, "bucketCounts" => [] }
      } ] } } ] } ] } ] })
    series = project.measurement_series.sole
    expect(series.metric_type).to eq("exponentialHistogram")
    get "/api/v1/measurement_series/#{series.id}/aggregation", params: { from: Time.at(1).utc.iso8601, to: Time.at(2).utc.iso8601, quantiles: [ "0.5" ] }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "buckets").sole.fetch("quantiles").sole).to include("status" => "known", "estimate" => "1.5")
    config = { "version" => 1, "statistic" => "percentile", "comparison" => "gt", "threshold" => "1", "window_seconds" => 60, "quantile" => "0.5" }
    expect(Alerting::Measurements::Configuration.validate!(config, series: series)).to eq(config)
    get "/api/v1/measurement_series/#{series.id}/aggregation", params: { from: Time.at(1).utc.iso8601, to: Time.at(86401).utc.iso8601, quantiles: [ "0.1", "0.5", "0.9", "0.95", "0.99" ] }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "message")).to include("percentile estimates")
  end

  it "returns typed filtered series and declared percentile uncertainty through the real API" do
    Measurements::Ingest::Record.call(project: project, payload: { "resourceMetrics" => [ {
      "resource" => { "attributes" => [ { "key" => "service.name", "value" => { "stringValue" => "checkout" } } ] },
      "scopeMetrics" => [ { "metrics" => [ { "name" => "latency", "unit" => "ms", "histogram" => { "aggregationTemporality" => 1,
        "dataPoints" => [ { "startTimeUnixNano" => "1000000000", "timeUnixNano" => "2000000000", "count" => "4", "explicitBounds" => [ 0, 10 ], "bucketCounts" => %w[0 4 0] } ] } } ] } ] } ] })
    get "/api/v1/measurement_series", params: { filters: { service_name: "checkout" }.to_json }, headers: headers
    expect(response).to have_http_status(:ok)
    row = response.parsed_body.fetch("data").sole
    expect(row.fetch("resource_identity")).to include("service_name" => "checkout", "environment" => nil)
    expect(row["identity_digest"]).to match(/\A[0-9a-f]{64}\z/)
    path = "/api/v1/measurement_series/#{row['id']}/aggregation"
    get path, params: { from: Time.at(1).utc.iso8601, to: Time.at(2).utc.iso8601, quantiles: [ "0.5" ] }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "buckets").sole.fetch("quantiles").sole).to include("estimate" => "5", "lower_bound" => "0", "upper_bound" => "10", "method" => "linear_bucket_v1")
    get path, params: { from: Time.at(1.5).utc.iso8601(9), to: Time.at(2).utc.iso8601, quantiles: [ "0.5" ] }, headers: headers
    bucket = response.parsed_body.dig("data", "buckets").sole
    expect(bucket).to include("status" => "unknown")
    expect(bucket.fetch("quantiles").sole).to include("estimate" => nil, "diagnostics" => include("bucket_boundary"))
    get path, params: { from: Time.at(1).utc.iso8601, to: Time.at(2).utc.iso8601, quantiles: [ "2" ] }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    get "/api/v1/measurement_series", params: { filters: { id: "-" * 36 }.to_json }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
  end
end
