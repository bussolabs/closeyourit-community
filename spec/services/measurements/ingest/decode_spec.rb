# frozen_string_literal: true

require "rails_helper"

RSpec.describe Measurements::Ingest::Decode do
  def export(type, points, **descriptor)
    { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ { "name" => "requests", "unit" => "1", type => { "dataPoints" => points }.merge(descriptor.stringify_keys) } ] } ] } ] }
  end

  let(:point) { { "startTimeUnixNano" => "1000000000", "timeUnixNano" => "2000000000", "asInt" => "9223372036854775807" } }

  it "preserves exact signed integers, temporality and monotonicity" do
    result = described_class.call(payload: export("sum", [ point ], aggregationTemporality: 1, isMonotonic: true))
    expect(result.rejected).to eq(0)
    expect(result.points.sole[:series]).to include(metric_type: "sum", temporality: 1, monotonic: true)
    expect(result.points.sole[:payload]["asInt"]).to eq("9223372036854775807")
  end

  it "reports summary points as unsupported rather than converting them" do
    result = described_class.call(payload: export("summary", [ point.except("asInt") ]))
    expect(result.rejected).to eq(1)
    expect(result.points).to be_empty
  end

  it "retains no-recorded-value markers without inventing a numeric zero" do
    result = described_class.call(payload: export("gauge", [ point.except("asInt").merge("flags" => 1) ]))
    expect(result.points.sole[:payload]).to include("flags" => 1)
    expect(result.points.sole[:payload]).not_to have_key("asInt")
    expect(result.points.sole[:payload]).not_to have_key("asDouble")
  end

  %w[gauge sum histogram exponentialHistogram].each do |type|
    it "ignores meaningless values and exemplars on #{type} no-recorded-value markers" do
      marker = point.merge("flags" => 1, "asDouble" => "invalid", "bucketCounts" => "invalid", "exemplars" => [ { "timeUnixNano" => "1" } ])
      result = described_class.call(payload: export(type, [ marker ], aggregationTemporality: 2))
      expect(result.rejected).to eq(0)
      expect(result.points.sole[:payload].keys).to contain_exactly("startTimeUnixNano", "timeUnixNano", "attributes", "flags")
    end
  end

  it "rejects negative monotonic sums but retains valid nonmonotonic and nonfinite types" do
    expect(described_class.call(payload: export("sum", [ point.merge("asInt" => "-5") ], aggregationTemporality: 1, isMonotonic: true)).rejected).to eq(1)
    expect(described_class.call(payload: export("sum", [ point.merge("asInt" => "-5") ], aggregationTemporality: 1, isMonotonic: false)).rejected).to eq(0)
    result = described_class.call(payload: export("gauge", [ point.except("asInt").merge("asDouble" => "NaN") ]))
    expect(result.points.sole[:payload]["asDouble"]).to eq("NaN")
  end

  it "validates explicit and exponential counts and preserves exemplars with private attributes scrubbed" do
    histogram = point.except("asInt").merge("count" => "2", "sum" => 10.0, "explicitBounds" => [ 5.0 ], "bucketCounts" => %w[1 1],
      "exemplars" => [ { "timeUnixNano" => "1500000000", "asInt" => "8", "traceId" => "a" * 32, "spanId" => "b" * 16,
        "filteredAttributes" => [ { "key" => "password", "value" => { "stringValue" => "private-value" } } ] } ])
    result = described_class.call(payload: export("histogram", [ histogram ], aggregationTemporality: 1))
    expect(result.rejected).to eq(0)
    expect(result.points.sole[:payload].dig("exemplars", 0, "spanId")).to eq("b" * 16)
    expect(result.points.to_json).not_to include("private-value")
    expect(described_class.call(payload: export("histogram", [ histogram.merge("count" => "3") ], aggregationTemporality: 1)).rejected).to eq(1)
    exponential = point.except("asInt").merge("count" => "3", "zeroCount" => "1", "scale" => 2,
      "positive" => { "offset" => -1, "bucketCounts" => %w[1 1] })
    expect(described_class.call(payload: export("exponentialHistogram", [ exponential ], aggregationTemporality: 2)).rejected).to eq(0)
  end
end
