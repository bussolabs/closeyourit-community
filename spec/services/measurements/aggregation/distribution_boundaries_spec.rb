# frozen_string_literal: true

require "rails_helper"

RSpec.describe Measurements::Aggregation::Distribution, "histogram algebra boundaries" do
  def explicit(**values)
    { "count" => "1", "sum" => "1", "min" => "1", "max" => "1", "explicitBounds" => [ 0 ], "bucketCounts" => %w[0 1] }.merge(values.stringify_keys)
  end

  def exponential(scale: 0, offset: 0, counts: [ "1" ])
    { "count" => counts.sum(&:to_i).to_s, "scale" => scale, "zeroCount" => "0", "zeroThreshold" => 0,
      "positive" => { "offset" => offset, "bucketCounts" => counts },
      "negative" => { "offset" => 0, "bucketCounts" => [] } }
  end

  it "preserves extrema while merging but never carries them into a difference" do
    left, right = explicit, explicit(min: "-2", max: "4")
    expect(described_class.combine(left, right, type: "histogram")).to include("min" => BigDecimal("-2"), "max" => BigDecimal("4"))
    expect(described_class.combine(left, right, type: "histogram", subtract: true)).not_to have_key("min")
    expect { described_class.combine(left, explicit(sum: "2"), type: "histogram", subtract: true) }.to raise_error(described_class::Unknown, "reset_or_overlap")
  end

  it "rejects nonfinite sums instead of creating a nonfinite aggregate" do
    [ "NaN", "Infinity", "-Infinity" ].each do |sum|
      expect { described_class.combine(explicit(sum: sum), explicit, type: "histogram") }.to raise_error(described_class::Unknown, "nonfinite")
    end
  end

  it "bounds both explicit input allocation and exponential input allocation" do
    values = [ "0" ] * (described_class::MAX_BUCKETS + 1)
    value = explicit(bucketCounts: values)
    expect { described_class.combine(value, value, type: "histogram") }.to raise_error(described_class::Unknown, "histogram_budget")
    value = exponential(counts: values)
    expect { described_class.combine(value, value, type: "exponential_histogram") }.to raise_error(described_class::Unknown, "histogram_budget")
  end

  it "combines empty sides and reduces very distant scales without allocating huge shifts" do
    empty = exponential(scale: -100, counts: [])
    result = described_class.combine(exponential(scale: 100, offset: -1, counts: %w[2 3]), empty, type: "exponential_histogram")
    expect(result["positive"]).to eq("offset" => -1, "bucketCounts" => %w[2 3])
    expect(result["negative"]).to eq("offset" => 0, "bucketCounts" => [])
    expect(result["count"]).to eq("5")
  end
end
