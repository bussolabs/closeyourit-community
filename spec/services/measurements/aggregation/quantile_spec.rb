# frozen_string_literal: true

require "rails_helper"

RSpec.describe Measurements::Aggregation::Quantile do
  def estimate(value, q = "0.5", type: "histogram")
    described_class.call(distribution: value, type: type, quantile: q)
  end

  it "reports a declared estimate and bucket uncertainty instead of an exact percentile" do
    value = { "count" => "4", "bucketCounts" => %w[0 4 0], "explicitBounds" => [ 0, 10 ] }
    expect(estimate(value)).to include(status: "known", estimate: "5", lower_bound: "0", upper_bound: "10",
      lower_inclusive: false, upper_inclusive: true, method: "linear_bucket_v1")
    expect(estimate(value, "0")[:estimate]).to eq("0")
    expect(estimate(value, "1")[:estimate]).to eq("10")
  end

  it "keeps uint64 counts exact and handles negative explicit buckets" do
    count = (2**64 - 1).to_s
    value = { "count" => count, "bucketCounts" => [ "0", count, "0" ], "explicitBounds" => [ -10, 0 ] }
    expect(estimate(value)[:estimate]).to eq("-5")
  end

  it "does not manufacture values from empty, open ended or incoherent distributions" do
    expect(estimate({ "count" => "0", "bucketCounts" => %w[0 0], "explicitBounds" => [ 5 ] })[:diagnostics]).to eq([ "empty_distribution" ])
    expect(estimate({ "count" => "1", "bucketCounts" => %w[1 0], "explicitBounds" => [ 5 ] })[:diagnostics]).to eq([ "unbounded_bucket" ])
    expect(estimate({ "count" => "2", "bucketCounts" => %w[0 1 0], "explicitBounds" => [ 0, 5 ] })[:status]).to eq("unknown")
  end

  it "orders negative exponential buckets and represents an exact zero bucket" do
    value = { "count" => "4", "scale" => 0, "zeroThreshold" => 0, "zeroCount" => "0",
      "positive" => { "offset" => 0, "bucketCounts" => [] },
      "negative" => { "offset" => 0, "bucketCounts" => %w[2 2] } }
    result = estimate(value, "0.25", type: "exponential_histogram")
    expect(result[:estimate]).to eq("-3")
    expect(result).to include(lower_bound: "-4", upper_bound: "-2", lower_inclusive: true, upper_inclusive: false)
    value.merge!("count" => "2", "zeroCount" => "2", "negative" => { "offset" => 0, "bucketCounts" => [] })
    expect(estimate(value, type: "exponential_histogram")).to include(estimate: "0", lower_bound: "0", upper_bound: "0")
  end

  it "rejects unrepresentable exponential boundaries without allocating enormous powers" do
    value = { "count" => "1", "scale" => -(2**31), "zeroThreshold" => 0, "zeroCount" => "0",
      "positive" => { "offset" => 1, "bucketCounts" => [ "1" ] }, "negative" => { "offset" => 0, "bucketCounts" => [] } }
    expect(estimate(value, type: "exponential_histogram")[:diagnostics]).to eq([ "unrepresentable_bounds" ])
  end

  it "rejects incoherent side geometry even when the selected quantile lies in the zero bucket" do
    value = { "count" => "2", "scale" => 0, "zeroThreshold" => 5, "zeroCount" => "1",
      "positive" => { "offset" => 0, "bucketCounts" => [ "1" ] }, "negative" => { "offset" => 0, "bucketCounts" => [] } }
    expect(estimate(value, "0.25", type: "exponentialHistogram")[:diagnostics]).to eq([ "invalid_distribution" ])
  end
end
