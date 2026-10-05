# frozen_string_literal: true

require "rails_helper"

RSpec.describe Traces::Browse::Window do
  let(:now) { Time.utc(2026, 10, 4, 12) }

  it "defaults to a bounded received-time day and accepts exact nanosecond custom times" do
    value = described_class.call(params: {}, now: now)
    expect(value.from).to eq(now - 24.hours)
    expect(value.to).to eq(now)
    value = described_class.call(params: { from: "2026-10-04T10:00:00.000000001Z", to: "2026-10-04T10:00:00.000000003Z" }, now: now)
    expect(value.to.to_r - value.from.to_r).to eq(Rational(2, 1_000_000_000))
  end

  it "rejects malformed, reversed, future, missing and overlong custom periods" do
    [ { from: [] }, { range: {} }, { from: "2026-02-31T10:00Z", to: "2026-03-04T10:00Z" },
      { from: "2026-10-04T10:00+99:99", to: "2026-10-04T11:00Z" },
      { from: "2026-10-04T11:00Z", to: "2026-10-04T10:00Z" },
      { from: "2026-10-04T11:00Z", to: "2026-10-05T10:00Z" },
      { from: "2026-09-01T10:00Z", to: "2026-10-03T10:00Z" } ].each do |params|
      expect { described_class.call(params: params, now: now) }.to raise_error(Traces::Browse::Invalid)
    end
  end
end
