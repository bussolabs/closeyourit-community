# frozen_string_literal: true

require "rails_helper"

RSpec.describe Member::MeasurementsHelper, type: :helper do
  def chart(values)
    buckets = values.map { |value| { status: value.nil? ? "unknown" : "known", value: { last: value }, start_time_unix_nano: "1000000000", time_unix_nano: "2000000000" } }
    helper.measurement_chart(buckets, Struct.new(:unit).new("ms"), "last")
  end

  it "draws signed values from zero and preserves known zero versus missing samples" do
    negative = chart([ -9, 0 ])
    expect(negative[:bars].map { |bar| [ bar[:height], bar[:bottom] ] }).to eq([ [ 100, 0 ], [ 0, 100 ] ])
    mixed = chart([ -9, 9 ])
    expect(mixed[:bars].map { |bar| [ bar[:height], bar[:bottom] ] }).to eq([ [ 50, 0 ], [ 50, 50 ] ])
    expect(mixed[:gridlines]).to include(hash_including(value: "0 ms", pct: 50, baseline: true))
    expect(chart([ 0 ])[:bars].first).to include(height: 0, bottom: 50, unsampled: false)
    expect(chart([ nil ])[:bars].first).to include(unsampled: true)
  end

  it "keeps seconds and nonzero nanoseconds in bucket labels" do
    first = helper.measurement_timestamp("1791108000001000000")
    second = helper.measurement_timestamp("1791108000005000000")
    expect(first).to include(":00.001 ")
    expect(second).to include(":00.005 ")
    expect(first).not_to eq(second)
  end
end
