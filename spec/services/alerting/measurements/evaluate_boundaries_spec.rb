# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Measurements::Evaluate do
  let(:project) { create(:project) }
  let(:ending) { Time.utc(2026, 10, 4, 12, 1) }
  let(:series) do
    Measurements::Ingest::Record.call(project: project, payload: { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ {
      "name" => "temperature", "unit" => "Cel", "gauge" => { "dataPoints" => [ { "timeUnixNano" => ((ending.to_i - 1) * 1_000_000_000).to_s, "asInt" => "10" } ] }
    } ] } ] } ] })
    project.measurement_series.sole
  end
  let(:config) { { "version" => 1, "statistic" => "last", "comparison" => "gt", "threshold" => "5", "window_seconds" => 60 } }
  let(:rule) { create(:alerting_rule, organization: project.organization, project: project, event_type: :measurement_threshold, measurement_series: series, measurement_config: config) }

  it "ignores malformed windows, unknown rules and windows inside the grace interval" do
    [ "invalid", ending + 1.second, ending + 0.1 ].each do |window|
      expect(described_class.call(rule_id: rule.id, window_end: window, at: ending + 31.seconds)).to be_nil
    end
    expect(described_class.call(rule_id: rule.id, window_end: ending, at: ending + 29.seconds)).to be_nil
    expect(described_class.call(rule_id: SecureRandom.uuid, window_end: ending, at: ending + 31.seconds)).to be_nil
    expect(Alerting::Evaluation.where(rule_id: rule.id)).to be_empty
  end

  it "stops retrying unknown windows after five minutes without changing their prior result" do
    missing_end = ending + 60.seconds
    first = described_class.call(rule_id: rule.id, window_end: missing_end, at: missing_end + 31.seconds)
    expect(first.status).to eq("unknown")
    expect(first.retry_at).to eq(missing_end + 91.seconds)
    last = described_class.call(rule_id: rule.id, window_end: missing_end, at: missing_end + 300.seconds)
    expect(last.retry_at).to be_nil
    before = last.attributes
    late = described_class.call(rule_id: rule.id, window_end: missing_end, at: missing_end + 301.seconds)
    expect(late.attributes).to eq(before)
  end

  it "records rejected stored configurations as unknown without dispatching" do
    rule.update_columns(measurement_config: config.merge("statistic" => "sum"))
    result = described_class.call(rule_id: rule.id, window_end: ending, at: ending + 31.seconds)
    expect(result).to have_attributes(status: "unknown", dispatch_state: "none")
    expect(result.result["diagnostics"]).to eq([ "query_rejected" ])
  end

  it "evaluates percentile uncertainty and unbounded estimates from real histogram points" do
    point = { "startTimeUnixNano" => ((ending.to_i - 60) * 1_000_000_000).to_s, "timeUnixNano" => (ending.to_i * 1_000_000_000).to_s,
      "count" => "2", "bucketCounts" => %w[0 2 0], "explicitBounds" => [ 0, 10 ] }
    Measurements::Ingest::Record.call(project: project, payload: { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ {
      "name" => "latency", "histogram" => { "aggregationTemporality" => 1, "dataPoints" => [ point ] }
    } ] } ] } ] })
    histogram = project.measurement_series.find_by!(name: "latency")
    rule = create(:alerting_rule, organization: project.organization, project: project, event_type: :measurement_threshold,
      measurement_series: histogram, measurement_config: config.merge("statistic" => "percentile", "quantile" => "0.5"))
    uncertain = described_class.call(rule_id: rule.id, window_end: ending, at: ending + 31.seconds)
    expect(uncertain.status).to eq("unknown")
    expect(uncertain.result["diagnostics"]).to include("bucket_uncertainty")
    rule.update!(measurement_config: rule.measurement_config.merge("threshold" => "20"))
    expect(described_class.call(rule_id: rule.id, window_end: ending, at: ending + 31.seconds).status).to eq("safe")
    histogram.points.sole.update!(payload: point.merge("bucketCounts" => %w[0 0 2]))
    rule.update!(measurement_config: rule.measurement_config.merge("threshold" => "30"))
    unbounded = described_class.call(rule_id: rule.id, window_end: ending, at: ending + 31.seconds)
    expect(unbounded.status).to eq("unknown")
    expect(unbounded.result.fetch("quantile").fetch("status")).to eq("unknown")
  end
end
