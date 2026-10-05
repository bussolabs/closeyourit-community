# frozen_string_literal: true

require "rails_helper"

RSpec.describe Member::TracesHelper, type: :helper do
  it "formats exact nanosecond durations without rounding missing values to zero" do
    expect(helper.trace_duration(0)).to eq("0 ms")
    expect(helper.trace_duration(1)).to eq("0.000001 ms")
    expect(helper.trace_duration(100_000_000)).to eq("100 ms")
    expect(helper.trace_duration(9_007_199_254_740_993)).to eq("9007199254.740993 ms")
    expect(helper.trace_duration(nil)).not_to eq("0 ms")
  end

  it "shows a byte-budget notice instead of silently truncated evidence" do
    span = Struct.new(:resource, :instrumentation_scope, :payload).new({}, {}, { "value" => "x" * 64.kilobytes })
    expect(helper.trace_evidence(span)).to be_nil
    span.payload = { "value" => "safe" }
    expect(JSON.parse(helper.trace_evidence(span))).to include("payload" => { "value" => "safe" })
  end
end
