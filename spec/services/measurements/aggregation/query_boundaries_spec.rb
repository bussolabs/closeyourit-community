# frozen_string_literal: true

require "rails_helper"

RSpec.describe Measurements::Aggregation::Query do
  let(:project) { create(:project) }

  def record(type, points, temporality: 1, monotonic: true)
    data = { "dataPoints" => points }
    data.merge!("aggregationTemporality" => temporality, "isMonotonic" => monotonic) unless type == "gauge"
    Measurements::Ingest::Record.call(project: project, payload: { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ { "name" => "observations", type => data } ] } ] } ] })
    project.measurement_series.sole
  end

  def point(start, finish, value)
    { "startTimeUnixNano" => (start * 1_000_000_000).to_s, "timeUnixNano" => (finish * 1_000_000_000).to_s, "asInt" => value.to_s }
  end

  def aggregate(series, from: 1, to: 3, interval: 60)
    described_class.call(series: series, from: Time.at(from).utc.iso8601(9), to: Time.at(to).utc.iso8601(9), interval_seconds: interval)
  end

  it "rejects invalid percentile collections and percentiles on gauge series" do
    series = record("gauge", [ point(0, 2, 1) ])
    [ nil, "0.5", [ "0.1" ] * 6, [ "0.5" ] ].each do |quantiles|
      expect { described_class.call(series: series, from: Time.at(1).utc.iso8601, to: Time.at(3).utc.iso8601, quantiles: quantiles) }.to raise_error(described_class::Invalid)
    end
  end

  it "keeps a gauge window unknown if any sample explicitly has no recorded value" do
    series = record("gauge", [ point(0, 2, 1), point(0, 3, 0).except("asInt").merge("flags" => 1) ])
    expect(aggregate(series)[:buckets].sole).to include(status: "unknown", diagnostics: [ "no_recorded_value" ])
  end

  it "does not infer cumulative deltas across a missing baseline or repeated reset" do
    series = record("sum", [ point(1, 2, 0).except("asInt").merge("flags" => 1), point(1, 3, 10) ], temporality: 2)
    expect(aggregate(series, from: 2)[:buckets].sole[:diagnostics]).to include("unknown_baseline")
    record("sum", [ point(1, 4, 2), point(1, 5, 4) ], temporality: 2)
    expect(aggregate(series, from: 3, to: 5)[:buckets].sole[:diagnostics]).to include("reset_or_overlap")
  end

  it "rejects cumulative histogram subtraction with incompatible boundaries" do
    base = point(1, 2, 0).except("asInt").merge("count" => "1", "bucketCounts" => %w[1 0], "explicitBounds" => [ 5 ])
    later = base.merge("timeUnixNano" => "3000000000", "count" => "2", "bucketCounts" => %w[2 0], "explicitBounds" => [ 10 ])
    series = record("histogram", [ base, later ], temporality: 2)
    expect(aggregate(series, from: 2)[:buckets].sole).to include(status: "unknown", value: nil)
  end

  it "limits percentile bucket visits without allocating an unbounded response" do
    series = record("histogram", [ point(1, 2, 0).except("asInt").merge("count" => "1", "bucketCounts" => %w[1 0], "explicitBounds" => [ 5 ]) ])
    query = described_class.new(series: series, from: Time.at(1).utc.iso8601, to: Time.at(3).utc.iso8601, quantiles: %w[0.25 0.5 0.75])
    distribution = { "count" => "1", "bucketCounts" => [ "0" ] * 4096, "explicitBounds" => (1..4095).to_a }
    bucket = { status: "known", value: distribution }
    8.times { query.send(:estimates, bucket) }
    expect { query.send(:estimates, bucket) }.to raise_error(described_class::Invalid, /bucket budget/)
  end
end
