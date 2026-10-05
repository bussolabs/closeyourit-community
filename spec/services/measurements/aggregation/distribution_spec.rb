# frozen_string_literal: true

require "rails_helper"

RSpec.describe Measurements::Aggregation::Distribution do
  def exponential(scale, offset, positive, negative)
    { "count" => (positive.sum + negative.sum).to_s, "scale" => scale, "zeroCount" => "0", "zeroThreshold" => 0,
      "positive" => { "offset" => offset, "bucketCounts" => positive.map(&:to_s) },
      "negative" => { "offset" => offset, "bucketCounts" => negative.map(&:to_s) } }
  end

  it "downscales exponential buckets using floor indices, including negative offsets" do
    left = exponential(1, -2, [ 1, 2 ], [ 1, 1 ])
    right = exponential(0, -1, [ 3 ], [ 2 ])
    result = described_class.combine(left, right, type: "exponentialHistogram")
    expect(result).to include("count" => "10", "scale" => 0)
    expect(result["positive"]).to eq("offset" => -1, "bucketCounts" => [ "6" ])
    expect(result["negative"]).to eq("offset" => -1, "bucketCounts" => [ "4" ])
  end

  it "differences compatible cumulative histogram populations without inventing interval minima" do
    left = { "count" => "3", "sum" => 12.0, "min" => 1.0, "max" => 8.0, "explicitBounds" => [ 5.0 ], "bucketCounts" => %w[2 1] }
    right = left.merge("count" => "2", "sum" => 4.0, "bucketCounts" => %w[2 0])
    result = described_class.combine(left, right, type: "histogram", subtract: true)
    expect(result).to include("count" => "1", "sum" => BigDecimal("8"), "bucketCounts" => %w[0 1])
    expect(result).not_to have_key("min")
    expect(result).not_to have_key("max")
  end

  it "rejects incompatible layouts, negative differences and unbounded output ranges" do
    left = exponential(1, 0, [ 1 ], [])
    expect { described_class.combine(left, left.merge("zeroThreshold" => 1), type: "exponentialHistogram") }.to raise_error(described_class::Unknown, "incompatible_layout")
    distant = exponential(1, 1_000_000_000, [ 1 ], [])
    expect { described_class.combine(left, distant, type: "exponentialHistogram") }.to raise_error(described_class::Unknown, "histogram_budget")
    larger = exponential(1, 0, [ 2 ], [])
    expect { described_class.combine(left, larger, type: "exponentialHistogram", subtract: true) }.to raise_error(described_class::Unknown, "reset_or_overlap")
  end

  it "bounds total output buckets for a single point and across positive and negative ranges" do
    oversized = exponential(1, 0, Array.new(2049, 1), Array.new(2049, 1))
    expect { described_class.clean(oversized, type: "exponentialHistogram") }.to raise_error(described_class::Unknown, "histogram_budget")
  end

  it "rejects an explicit boundary change instead of adding incompatible bucket positions" do
    left = { "count" => "1", "explicitBounds" => [ 5.0 ], "bucketCounts" => %w[1 0] }
    right = left.merge("explicitBounds" => [ 10.0 ])
    expect { described_class.combine(left, right, type: "histogram") }.to raise_error(described_class::Unknown, "incompatible_layout")
  end
end
