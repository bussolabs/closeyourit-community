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

  it "sums contiguous delta intervals and computes a rate from covered time" do
    series = record("sum", [ point(1, 2, 10), point(2, 3, 5) ])
    result = aggregate(series)[:buckets].sole
    expect(result).to include(status: "known", value: { sum: "15", rate: "7.5" })
  end

  it "differences cumulative counters using a preceding baseline without adding both totals" do
    series = record("sum", [ point(1, 2, 10), point(1, 3, 15) ], temporality: 2)
    expect(aggregate(series, from: 2)[:buckets].sole).to include(status: "known", value: { sum: "5", rate: "5" })
  end

  it "keeps gauge observations distinct from additive totals" do
    series = record("gauge", [ point(0, 2, 7), point(0, 3, 9) ])
    expect(aggregate(series)[:buckets].sole).to include(status: "known", value: { last: "9", min: "7", max: "9" })
  end

  it "reports gaps, overlaps, bucket boundaries and empty windows without inventing zero" do
    series = record("sum", [ point(1, 2, 10), point(3, 4, 5) ])
    expect(aggregate(series, to: 4)[:buckets].sole).to include(status: "unknown", value: nil)
    expect(aggregate(series, to: 4)[:buckets].sole[:diagnostics]).to include("gap")
    expect(aggregate(series, from: 5, to: 6)[:buckets].sole).to include(status: "unknown", value: nil, diagnostics: [ "no_data" ])
    expect(aggregate(series, from: 1.5, to: 2)[:buckets].sole[:diagnostics]).to include("bucket_boundary")
  end

  it "diagnoses a cumulative monotonic drop and no-recorded-value at the bucket endpoint" do
    series = record("sum", [ point(1, 2, 10), point(1, 3, 5) ], temporality: 2)
    expect(aggregate(series, from: 2)[:buckets].sole).to include(status: "unknown", value: nil)
    marker = point(1, 4, 0).except("asInt").merge("flags" => 1)
    record("sum", [ marker ], temporality: 2)
    expect(aggregate(series, from: 3, to: 4)[:buckets].sole[:diagnostics]).to include("no_recorded_value")
  end

  it "combines histogram distributions and preserves their bucket counts" do
    hist = ->(start, finish, count, sum, buckets) { point(start, finish, 0).except("asInt").merge("count" => count.to_s, "sum" => sum, "explicitBounds" => [ 5.0, 10.0 ], "bucketCounts" => buckets.map(&:to_s)) }
    series = record("histogram", [ hist.call(1, 2, 2, 10.0, [ 1, 1, 0 ]), hist.call(2, 3, 1, 20.0, [ 0, 0, 1 ]) ])
    expect(aggregate(series)[:buckets].sole[:value]).to include("count" => "3", "sum" => "30", "bucketCounts" => %w[1 1 1])
  end

  it "rejects invalid and oversized query windows" do
    series = record("gauge", [ point(0, 2, 1) ])
    expect { aggregate(series, from: 3, to: 2) }.to raise_error(described_class::Invalid)
    expect { aggregate(series, from: 1, to: 2000, interval: 1) }.to raise_error(described_class::Invalid)
  end

  it "distinguishes a known contiguous reset from an unexplained reset gap" do
    series = record("sum", [ point(1, 2, 10), point(2, 3, 3) ], temporality: 2)
    result = aggregate(series)[:buckets].sole
    expect(result).to include(status: "known", value: { sum: "13", rate: "6.5" })
    expect(result[:diagnostics]).to include("reset")
    record("sum", [ point(4, 5, 2) ], temporality: 2)
    expect(aggregate(series, to: 5)[:buckets].sole).to include(status: "unknown", value: nil)
  end

  it "reports overlapping delta windows as unknown" do
    series = record("sum", [ point(1, 3, 10), point(2, 4, 5) ])
    expect(aggregate(series, to: 4)[:buckets].sole[:diagnostics]).to include("overlap")
  end

  it "enforces input byte and row budgets before loading unbounded point payloads" do
    series = record("gauge", [ point(0, 2, 7), point(0, 3, 9) ])
    stub_const("Measurements::Aggregation::Query::MAX_PAYLOAD_BYTES", 1)
    expect { aggregate(series) }.to raise_error(described_class::Invalid, "Aggregation input exceeds the byte limit")
    stub_const("Measurements::Aggregation::Query::MAX_POINTS", 1)
    expect { aggregate(series) }.to raise_error(described_class::Invalid, "Too many points in aggregation window")
  end

  it "requires explicit timestamp offsets and preserves nanosecond precision" do
    series = record("gauge", [ point(0, 2, 7) ])
    %w[1970-01-01T00:00:01 1970-01-01 1970-01-01T00:00:01.1234567891Z 1970-02-31T00:00:01Z].each do |invalid|
      expect { described_class.call(series: series, from: invalid, to: "1970-01-01T00:00:03Z") }.to raise_error(described_class::Invalid)
    end
    result = described_class.call(series: series, from: "1970-01-01T01:00:01.000000001+01:00", to: "1970-01-01T00:00:03Z")
    expect(result[:from_unix_nano]).to eq("1000000001")
  end

  it "keeps a nonfinite gauge value unknown rather than turning it into zero" do
    series = record("gauge", [ point(0, 2, 0).except("asInt").merge("asDouble" => "NaN") ])
    expect(aggregate(series)[:buckets].sole).to include(status: "unknown", value: nil, diagnostics: [ "nonfinite" ])
  end
end
