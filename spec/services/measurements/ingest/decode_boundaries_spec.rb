# frozen_string_literal: true

require "rails_helper"

RSpec.describe Measurements::Ingest::Decode, "OTLP input boundaries" do
  def export(type, points, name: "requests")
    { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ { "name" => name,
      type => { "aggregationTemporality" => 1, "dataPoints" => points } } ] } ] } ] }
  end

  def point(**attributes)
    { "timeUnixNano" => "2000000000" }.merge(attributes.stringify_keys)
  end

  it "enforces one metric type and the total point budget" do
    payload = export("gauge", [ point(asInt: "1") ])
    metric = payload["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]
    metric["sum"] = metric["gauge"]
    expect { described_class.call(payload: payload) }.to raise_error(Ingest::OtlpValues::Malformed)
    expect(described_class.call(payload: export("gauge", [ point(asInt: "1") ] * 1000)).points.size).to eq(1000)
    expect { described_class.call(payload: export("gauge", [ point(asInt: "1") ] * 1001)) }.to raise_error(Ingest::OtlpValues::Malformed)
  end

  it "counts invalid names and ambiguous values as rejected points" do
    expect(described_class.call(payload: export("gauge", [ point(asInt: "1") ], name: "")).rejected).to eq(1)
    [ point, point(asInt: "1", asDouble: 1.0) ].each do |value|
      result = described_class.call(payload: export("gauge", [ value, point(asInt: "3") ]))
      expect(result.rejected).to eq(1)
      expect(result.points.sole[:payload]["asInt"]).to eq("3")
    end
  end

  it "rejects contradictory histogram summaries and layouts" do
    valid = point(count: "2", sum: 3, min: 1, max: 2, explicitBounds: [ 1 ], bucketCounts: %w[1 1])
    changes = [ { "count" => "0", "sum" => 1 }, { "sum" => -1 }, { "min" => 3 },
      { "explicitBounds" => [ 2, 1 ], "bucketCounts" => %w[0 1 1] },
      { "explicitBounds" => [ "Infinity" ] }, { "bucketCounts" => [] }, { "bucketCounts" => [ "2" ] } ]
    changes.each do |change|
      result = described_class.call(payload: export("histogram", [ valid.merge(change), valid ]))
      expect(result.rejected).to eq(1)
      expect(result.points.size).to eq(1)
    end
    expect(described_class.call(payload: export("histogram", [ point(count: "0") ])).rejected).to eq(0)
  end

  it "rejects invalid exponential thresholds and inconsistent totals" do
    valid = point(count: "2", zeroCount: "1", positive: { "offset" => 0, "bucketCounts" => [ "1" ] })
    [ { "zeroThreshold" => -1 }, { "zeroThreshold" => "NaN" }, { "count" => "3" } ].each do |change|
      expect(described_class.call(payload: export("exponentialHistogram", [ valid.merge(change) ])).rejected).to eq(1)
    end
  end
end
