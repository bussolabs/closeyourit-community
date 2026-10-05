# frozen_string_literal: true

require "rails_helper"

RSpec.describe SessionHealth::Query do
  let(:project) { create(:project) }

  def session(status, errors: 0, release: "v1", environment: "production")
    payload = { "sid" => SecureRandom.uuid, "started" => "2026-10-04T01:00:00Z", "timestamp" => "2026-10-04T01:01:00Z", "status" => status, "errors" => errors, "attrs" => { "release" => release, "environment" => environment } }
    items = SessionHealth::Ingest::Decode.call(type: "session", payload: payload).map { |value| { type: "session", value: value } }
    SessionHealth::Ingest::Record.call(project: project, items: items)
  end

  def query(**filters)
    described_class.new(sessions: project.health_sessions, aggregates: project.health_aggregates, **filters).call.records
  end

  it "computes a known-outcome denominator without treating open or abnormal sessions as healthy" do
    session("exited")
    session("exited", errors: 2)
    session("unhandled")
    session("crashed")
    session("abnormal")
    session("ok")
    expect(query.sole).to include("total" => "6", "exited" => "1", "errored" => "1", "unhandled" => "1", "crashed" => "1", "unknown" => "2", "numerator" => "3", "denominator" => "4", "crash_free_rate" => 0.75, "source" => "individual", "deduplication" => "sid")
  end

  it "returns no percentage for an unknown-only cohort and never mixes releases or environments" do
    session("ok")
    session("exited", release: "v2")
    session("crashed", release: "v2", environment: "staging")
    expect(query(release: "v1").sole).to include("denominator" => "0", "crash_free_rate" => nil)
    expect(query(release: "v2", environment: "production").sole["crash_free_rate"]).to eq(1.0)
    expect(query.size).to eq(3)
    expect(query(from: "2026-10-05T00:00:00Z")).to eq([])
  end

  it "rejects ambiguous, nonexistent or inverted timestamps" do
    [ { from: "2026-10-04T00:00:00" }, { from: "2026-02-31T00:00:00Z" }, { from: "2026-10-05T00:00:00Z", to: "2026-10-04T00:00:00Z" } ].each do |filters|
      expect { query(**filters) }.to raise_error(described_class::Invalid)
    end
  end
  it "keeps aggregate sums beyond uint64 exact as decimal strings" do
    maximum = 2**64 - 1
    value = { "attrs" => { "release" => "huge" }, "aggregates" => [ { "started" => "2026-10-04T01:00:00Z", "exited" => maximum, "crashed" => maximum } ] }
    items = SessionHealth::Ingest::Decode.call(type: "sessions", payload: value).map { |item| { type: "sessions", value: item } }
    2.times { SessionHealth::Ingest::Record.call(project: project, items: items) }
    expect(project.health_aggregates.pluck(:exited).map(&:to_i)).to eq([ maximum, maximum ])
    expect(query.sole).to include("exited" => (maximum * 2).to_s, "crashed" => (maximum * 2).to_s,
      "numerator" => (maximum * 2).to_s, "denominator" => (maximum * 4).to_s, "crash_free_rate" => 0.5)
  end
end
