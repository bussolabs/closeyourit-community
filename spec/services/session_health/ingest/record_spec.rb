# frozen_string_literal: true

require "rails_helper"

RSpec.describe SessionHealth::Ingest::Record do
  let(:project) { create(:project) }
  let(:payload) { { "sid" => SecureRandom.uuid, "init" => true, "started" => "2026-10-04T01:00:00Z", "timestamp" => "2026-10-04T01:00:00Z", "status" => "ok", "attrs" => { "release" => "app@1.0", "environment" => "production" } } }

  def admit(value = payload, type: "session", target: project)
    items = SessionHealth::Ingest::Decode.call(type: type, payload: value).map { |item| { type: type, value: item } }
    described_class.call(project: target, items: items)
  end

  it "updates official Python init-true states once and ignores later replays and older arrivals" do
    admit
    first = project.health_sessions.sole.created_at
    ended = payload.merge("status" => "exited", "timestamp" => "2026-10-04T01:01:00Z", "duration" => 60)
    expect(admit(ended).accepted).to eq(1)
    expect(admit(ended).duplicates).to eq(1)
    expect(admit(payload).stale).to eq(1)
    expect(project.health_sessions.sole).to have_attributes(status: "exited", observed_update_count: 2, created_at: first)
  end

  it "accepts final-first delivery without inventing a second session or regressing terminal state" do
    ended = payload.merge("status" => "crashed", "timestamp" => "2026-10-04T01:01:00Z")
    admit(ended)
    expect(admit(payload).stale).to eq(1)
    expect(admit(payload.merge("timestamp" => "2026-10-04T01:02:00Z")).rejected).to eq(1)
    expect(project.health_sessions.sole).to have_attributes(status: "crashed", errors_count: 1)
  end

  it "diagnoses same-clock conflicts and immutable attribute changes" do
    admit
    expect(admit(payload.merge("status" => "crashed")).rejected).to eq(1)
    expect(admit(payload.merge("attrs" => { "release" => "changed" })).rejected).to eq(1)
    expect(project.health_sessions.sole).to have_attributes(status: "ok", release: "app@1.0")
  end

  it "keeps aggregate deliveries and anonymous exited sessions distinct without heuristic deduplication" do
    aggregates = { "attrs" => payload["attrs"], "aggregates" => [ { "started" => payload["started"], "exited" => 2 } ] }
    2.times { admit(aggregates, type: "sessions") }
    2.times { admit(payload.except("sid").merge("status" => "exited")) }
    expect(project.health_aggregates.count).to eq(2)
    expect(project.health_aggregates.sum(:exited)).to eq(4)
    expect(project.health_sessions.count).to eq(2)
    expect(project.health_sessions.pluck(:producer_identity)).to eq([ false, false ])
  end

  it "isolates equal producer identities by project" do
    other = create(:project)
    admit
    admit(payload.merge("status" => "crashed"), target: other)
    expect(project.health_sessions.sole.status).to eq("ok")
    expect(other.health_sessions.sole.status).to eq("crashed")
  end
  it "deduplicates sessions that omit optional update clocks without refreshing retention" do
    item = payload.except("timestamp").merge("status" => "exited")
    admit(item)
    first = project.health_sessions.sole.created_at
    travel 1.minute do
      expect(admit(item).duplicates).to eq(1)
    end
    expect(project.health_sessions.sole.created_at).to eq(first)
  end

  it "batches one thousand session identities into a single write without per-session queries" do
    project
    items = Array.new(1_000) do
      value = SessionHealth::Ingest::Decode.call(type: "session", payload: payload.merge("sid" => SecureRandom.uuid)).sole
      { type: "session", value: value }
    end
    statements = []
    subscriber = ->(_name, _start, _finish, _id, data) { statements << data[:sql] if data[:name] != "SCHEMA" && data[:sql].include?("session_health_sessions") }
    result = nil
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { result = described_class.call(project: project, items: items) }
    expect(result.accepted).to eq(1_000)
    expect(project.health_sessions.count).to eq(1_000)
    expect(statements.count { |sql| sql.start_with?("INSERT INTO") }).to eq(1)
    expect(statements.size).to be <= 2
  end

  it "preserves unsigned maximum counters and clocks without a PostgreSQL signed-integer cast" do
    value = payload.merge("init" => false, "seq" => 2**64 - 1, "errors" => 2**64 - 1)
    admit(value)
    row = project.health_sessions.sole
    expect(row.sequence.to_i).to eq(2**64 - 1)
    expect(row.errors_count.to_i).to eq(2**64 - 1)
  end
  it "rolls back mixed session writes when an aggregate violates a database constraint" do
    project
    session = SessionHealth::Ingest::Decode.call(type: "session", payload: payload).sole
    aggregate = { release: "invalid", environment: nil, started_at: Time.current, exited: -1, errored: 0, crashed: 0, abnormal: 0, unhandled: 0 }
    expect { described_class.call(project: project, items: [ { type: "session", value: session }, { type: "sessions", value: aggregate } ]) }.to raise_error(ActiveRecord::StatementInvalid, /check constraint/)
    expect(project.health_sessions.count).to eq(0)
    expect(project.health_aggregates.count).to eq(0)
  end
end
