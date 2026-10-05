# frozen_string_literal: true

require "rails_helper"

RSpec.describe Measurements::Aggregation::Quantile, "distribution boundaries" do
  def estimate(value, type: "histogram", quantile: "0.5")
    described_class.call(distribution: value, type: type, quantile: quantile)
  end

  def histogram
    { "count" => "4", "bucketCounts" => %w[0 4 0], "explicitBounds" => [ 0, 10 ] }
  end

  def exponential
    { "count" => "1", "scale" => 0, "zeroThreshold" => 0, "zeroCount" => "0",
      "positive" => { "offset" => 0, "bucketCounts" => [ "1" ] },
      "negative" => { "offset" => 0, "bucketCounts" => [] } }
  end

  it "rejects quantile syntax outside the closed unit interval before calculation" do
    [ nil, 0.5, "-0.1", "1.1", "NaN", "0.5\n", "0." + "1" * 63 ].each do |quantile|
      expect { described_class.parse(quantile) }.to raise_error(ArgumentError, "Invalid quantile")
    end
    expect(described_class.parse("1.000")).to eq(BigDecimal("1"))
  end

  it "rejects malformed, negative and over-budget counts" do
    [ "-1", "1.5", "x", "9" * 25, (((2**64) - 1) * 10_000 + 1).to_s ].each do |count|
      expect(estimate(histogram.merge("count" => count))).to include(status: "unknown", diagnostics: [ "invalid_distribution" ])
    end
    expect(estimate(histogram.except("count"))).to include(status: "unknown", diagnostics: [ "invalid_distribution" ])
  end

  it "rejects nonfinite and unordered explicit bounds" do
    [ [ 0, "Infinity" ], [ 0, "NaN" ] ].each do |bounds|
      expect(estimate(histogram.merge("explicitBounds" => bounds))[:diagnostics]).to eq([ "nonfinite" ])
    end
    [ [ 10, 0 ], [ 0, 0 ] ].each do |bounds|
      expect(estimate(histogram.merge("explicitBounds" => bounds))[:diagnostics]).to eq([ "invalid_distribution" ])
    end
  end

  it "limits explicit bucket allocation even for zero-count tails" do
    size = Measurements::Aggregation::Distribution::MAX_BUCKETS
    value = { "count" => "1", "explicitBounds" => (0...size).to_a,
      "bucketCounts" => [ "0", "1" ] + [ "0" ] * (size - 1) }
    expect(estimate(value)[:diagnostics]).to eq([ "histogram_budget" ])
  end

  it "rejects negative zero thresholds and exponential bounds beyond the numeric range" do
    expect(estimate(exponential.merge("zeroThreshold" => -1), type: "exponential_histogram")[:diagnostics]).to eq([ "invalid_distribution" ])
    [ -1023, 1023 ].each do |offset|
      value = exponential.merge("positive" => { "offset" => offset, "bucketCounts" => [ "1" ] })
      expect(estimate(value, type: "exponential_histogram")[:diagnostics]).to eq([ "unrepresentable_bounds" ])
    end
  end

  it "counts sparse exponential buckets without treating empty slots as observations" do
    value = exponential.merge("positive" => { "offset" => 0, "bucketCounts" => %w[0 1 0] })
    expect(estimate(value, type: "exponential_histogram")).to include(status: "known", estimate: "3", lower_bound: "2", upper_bound: "4")
  end

  it "widens fractional exponential bounds around the mathematical boundary" do
    result = estimate(exponential.merge("scale" => 1), type: "exponential_histogram")
    expect(result[:status]).to eq("known")
    expect(BigDecimal(result[:lower_bound])).to eq(1)
    upper = BigDecimal(result[:upper_bound])
    expect(upper).to be > BigDecimal("2").sqrt(60)
    expect(upper - BigDecimal("2").sqrt(60)).to be < BigDecimal("1e-40")
  end

  it "applies the bucket budget to both exponential sides together" do
    count = Measurements::Aggregation::Distribution::MAX_BUCKETS / 2 + 1
    side = { "offset" => 0, "bucketCounts" => [ "1" ] * count }
    value = exponential.merge("scale" => 20, "count" => (count * 2).to_s, "positive" => side, "negative" => side)
    expect(estimate(value, type: "exponential_histogram")[:diagnostics]).to eq([ "histogram_budget" ])
    value["positive"] = side.merge("bucketCounts" => [ "0" ] * (Measurements::Aggregation::Distribution::MAX_BUCKETS + 1))
    expect(estimate(value, type: "exponential_histogram")[:diagnostics]).to eq([ "histogram_budget" ])
  end
end
