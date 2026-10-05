# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Telemetry SQL composition boundaries" do
  let(:project) { create(:project) }
  let(:other_project) { create(:project) }
  let(:hostile) { "literal' OR '1'='1 --" }

  def record_session(target, release:, environment:)
    payload = { "sid" => SecureRandom.uuid, "started" => "2026-10-04T01:00:00Z",
      "timestamp" => "2026-10-04T01:01:00Z", "status" => "exited",
      "attrs" => { "release" => release, "environment" => environment } }
    items = SessionHealth::Ingest::Decode.call(type: "session", payload: payload).map { |value| { type: "session", value: value } }
    SessionHealth::Ingest::Record.call(project: target, items: items)
  end

  def record_series(target, dimension)
    item = { "key" => "dimension", "value" => { "stringValue" => dimension } }
    Measurements::Ingest::Record.call(project: target, payload: { "resourceMetrics" => [ {
      "resource" => { "attributes" => [ item ] }, "scopeMetrics" => [ { "metrics" => [ {
        "name" => "reading", "gauge" => { "dataPoints" => [ {
          "timeUnixNano" => "1000000000", "asInt" => "1", "attributes" => [ item ]
        } ] }
      } ] } ]
    } ] })
    target.measurement_series.where("point_attributes = ?::jsonb", [ item ].to_json).sole
  end

  it "quotes hostile cohort filters and ignores unknown ordering without crossing projects" do
    record_session(project, release: hostile, environment: hostile)
    record_session(project, release: "ordinary", environment: "production")
    record_session(other_project, release: hostile, environment: hostile)
    result = SessionHealth::Query.new(sessions: project.health_sessions, aggregates: project.health_aggregates,
      release: hostile, environment: hostile).call(sort: hostile, page: "1 OR 1=1", per: "10 OR 1=1")
    expect(result.total).to eq(1)
    expect(result.records.sole).to include("project_id" => project.id, "release" => hostile, "environment" => hostile, "total" => "1")
    expect(project.health_sessions.count).to eq(2)
    expect(other_project.health_sessions.count).to eq(1)
  end

  it "quotes aggregate cohort filters in the union and retains project isolation" do
    record_session(project, release: hostile, environment: hostile)
    [ project, other_project ].each do |target|
      payload = { "attrs" => { "release" => hostile, "environment" => hostile },
        "aggregates" => [ { "started" => "2026-10-04T01:00:00Z", "exited" => 7 } ] }
      items = SessionHealth::Ingest::Decode.call(type: "sessions", payload: payload).map { |value| { type: "sessions", value: value } }
      SessionHealth::Ingest::Record.call(project: target, items: items)
    end
    result = SessionHealth::Query.new(sessions: project.health_sessions, aggregates: project.health_aggregates,
      release: hostile, environment: hostile).call(sort: hostile)
    expect(result.total).to eq(2)
    expect(result.records.map { |row| row.fetch("project_id") }.uniq).to eq([ project.id ])
    expect(result.records.map { |row| row.values_at("source", "total") }).to contain_exactly([ "individual", "1" ], [ "aggregate", "7" ])
  end

  it "binds hostile resource and point attribute values and preserves the incoming project scope" do
    expected = record_series(project, hostile)
    record_series(project, "ordinary")
    record_series(other_project, hostile)
    item = { "key" => "dimension", "value" => { "stringValue" => hostile } }
    %w[resource_attributes point_attributes].each do |column|
      result = Measurements::Series::Query.call(scope: project.measurement_series, filters: { column => [ item ] })
      expect(result.pluck(:id)).to eq([ expected.id ])
    end
    expect { Measurements::Series::Query.call(scope: project.measurement_series, filters: { hostile => [ item ] }) }
      .to raise_error(Measurements::Series::Query::Invalid)
  end

  it "acquires a real transaction lock with SQL-looking identity strings" do
    ApplicationRecord.transaction do
      expect { Ingest::EventLock.acquire!(project_id: project.id, event_id: hostile, domain: hostile) }.not_to raise_error
      expect { Ingest::EventLock.acquire!(project_id: project.id, event_id: hostile, domain: hostile) }.not_to raise_error
    end
  end
end
