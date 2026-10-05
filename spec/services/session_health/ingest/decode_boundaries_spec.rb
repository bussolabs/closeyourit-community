# frozen_string_literal: true

require "rails_helper"

RSpec.describe SessionHealth::Ingest::Decode do
  let(:payload) { { "attrs" => { "release" => "v1" }, "sid" => SecureRandom.uuid, "started" => "2026-10-05T12:00:00Z", "timestamp" => "2026-10-05T12:00:01Z" } }

  it "rejects unsupported types, nonboolean initialization and malformed attribute objects" do
    expect { described_class.call(type: "unknown", payload: payload) }.to raise_error(described_class::Invalid)
    [ payload.merge("init" => 1), payload.merge("attrs" => []), payload.merge("attrs" => { "release" => "a\0b" }),
      payload.merge("attrs" => { "release" => "x" * 1025 }), payload.merge("attrs" => { "release" => 1 }) ].each do |input|
      expect { described_class.call(type: "session", payload: input) }.to raise_error(described_class::Invalid)
    end
  end

  it "requires aggregate timestamps to begin on an exact minute" do
    [ "2026-10-05T12:00:01Z", "2026-10-05T12:00:00.000000001Z" ].each do |started|
      expect { described_class.call(type: "sessions", payload: payload.merge("aggregates" => [ { "started" => started } ])) }.to raise_error(described_class::Invalid)
    end
  end
end
