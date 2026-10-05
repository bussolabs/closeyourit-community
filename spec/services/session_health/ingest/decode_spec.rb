# frozen_string_literal: true

require "rails_helper"

RSpec.describe SessionHealth::Ingest::Decode do
  let(:payload) do
    { "sid" => "b7e34cda-7bad-4c74-bccb-618d973c71a2", "init" => true,
      "started" => "2026-10-04T01:00:00Z", "timestamp" => "2026-10-04T01:01:00Z", "status" => "exited",
      "attrs" => { "release" => "checkout@1.0", "environment" => "production", "ip_address" => "127.0.0.1", "user_agent" => "private-agent" }, "did" => "alice@example.test" }
  end

  it "normalizes the official individual format without storing user identity or client metadata" do
    item = described_class.call(type: "session", payload: payload).sole
    expect(item).to include(sid: payload["sid"], release: "checkout@1.0", environment: "production", status: "exited", sequence: 0)
    expect(item.to_json).not_to include("alice@example.test", "127.0.0.1", "private-agent")
  end

  it "keeps terminal unhandled and abnormal distinct from a process crash" do
    %w[unhandled abnormal crashed].each do |status|
      item = described_class.call(type: "session", payload: payload.merge("status" => status)).sole
      expect(item[:status]).to eq(status)
      expect(item[:errors]).to eq(1) if status == "crashed"
    end
  end

  it "retains anonymous aggregate deliveries without inventing an identity" do
    aggregate = { "attrs" => payload["attrs"], "aggregates" => [ { "started" => payload["started"], "exited" => 3, "errored" => 2, "crashed" => 1, "abnormal" => 1, "unhandled" => 1, "did" => "private-user" } ] }
    item = described_class.call(type: "sessions", payload: aggregate).sole
    expect(item).to include(exited: 3, errored: 2, crashed: 1, abnormal: 1, unhandled: 1)
    expect(item).not_to have_key(:sid)
    expect(item.to_json).not_to include("private-user")
  end

  it "validates identity, calendar, explicit time zone, counter boundaries and mandatory release" do
    invalid = [ payload.merge("sid" => "not-uuid"), payload.merge("started" => "2026-02-31T00:00:00Z"),
      payload.merge("timestamp" => "2026-10-04T01:00:00"), payload.merge("errors" => -1),
      payload.merge("duration" => Float::INFINITY), payload.merge("duration" => 10**400), payload.merge("attrs" => {}), payload.merge("status" => "unknown") ]
    invalid.each { |item| expect { described_class.call(type: "session", payload: item) }.to raise_error(described_class::Invalid) }
  end
  it "accepts zero aggregate groups and rejects negative counts or more than one thousand groups" do
    value = { "attrs" => payload["attrs"], "aggregates" => [] }
    expect(described_class.call(type: "sessions", payload: value)).to eq([])
    value["aggregates"] = [ { "started" => payload["started"], "exited" => -1 } ]
    expect { described_class.call(type: "sessions", payload: value) }.to raise_error(described_class::Invalid)
    value["aggregates"] = Array.new(1_001) { { "started" => payload["started"], "exited" => 1 } }
    expect { described_class.call(type: "sessions", payload: value) }.to raise_error(described_class::Invalid)
  end
  it "accepts compact JavaScript SDK session identifiers as the same canonical UUID" do
    item = described_class.call(type: "session", payload: payload.merge("sid" => payload["sid"].delete("-").upcase)).sole
    expect(item[:sid]).to eq(payload["sid"])
  end
end
