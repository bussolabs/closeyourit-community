# frozen_string_literal: true

require "rails_helper"

RSpec.describe Member::MeasurementsHelper, type: :helper do
  let(:series) { Measurements::Series.new(unit: "ms", metric_type: "gauge") }

  it "renders invalid values as unknown while preserving exact zero and decimal precision" do
    [ nil, "NaN", "Infinity", "invalid" ].each { |value| expect(helper.measurement_number(value)).to eq("—") }
    expect(helper.measurement_number("0")).to eq("0")
    expect(helper.measurement_number("0.000000001")).to eq("0.000000001")
  end

  it "preserves fractional timestamps without trailing zeroes" do
    expect(helper.measurement_timestamp("1000000001")).to include(".000000001 ")
    expect(helper.measurement_timestamp("1500000000")).to include(".5 ")
    expect(helper.measurement_timestamp("1000000000")).not_to include(".")
  end

  it "retains open and closed bucket bounds" do
    expect(helper.measurement_bounds(lower_bound: "0", upper_bound: "1", lower_inclusive: true, upper_inclusive: false)).to eq("[0, 1)")
  end

  it "never turns an unknown percentile or missing sample into zero" do
    [ { status: "unknown" }, { status: "known" }, { status: "known", quantiles: [] },
      { status: "known", quantiles: [ { status: "unknown", estimate: nil } ] } ].each do |bucket|
      expect(helper.measurement_bucket_value(bucket, "percentile")).to be_nil
    end
    expect(helper.measurement_latest(nil)).to be_nil
    expect(helper.measurement_latest(Measurements::Point.new(payload: { "flags" => 1, "asInt" => "7" }))).to be_nil
    expect(helper.measurement_latest(Measurements::Point.new(payload: { "asDouble" => 0.5 }))).to eq(0.5)
    expect(helper.measurement_latest(Measurements::Point.new(payload: { "count" => "0" }))).to eq("0")
  end

  it "renders an empty chart and a unitless rate without fabricating observations" do
    expect(helper.measurement_chart([], series, "last")).to include(bars: [], xticks: [])
    expect(helper.measurement_unit(Measurements::Series.new(unit: ""), "rate")).to eq("1/s")
  end
end
