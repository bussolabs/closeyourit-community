# frozen_string_literal: true

require "rails_helper"

RSpec.describe SessionHealth::PruneJob do
  let(:project) { create(:project) }

  def record(sid: SecureRandom.uuid, status: "ok")
    payload = { "sid" => sid, "init" => true, "started" => "2026-10-01T00:00:00Z", "timestamp" => Time.current.utc.iso8601(9), "status" => status, "attrs" => { "release" => "retained" } }
    items = SessionHealth::Ingest::Decode.call(type: "session", payload: payload).map { |value| { type: "session", value: value } }
    SessionHealth::Ingest::Record.call(project: project, items: items)
  end

  it "inherits the nearest explicit retention with a 30-day default and validates each settings boundary" do
    expect(SessionHealth::Retention.for(project)).to eq(30)
    project.organization.update!(session_health_retention_days: 60)
    expect(SessionHealth::Retention.for(project)).to eq(60)
    project.update!(session_health_retention_days: 365)
    expect(SessionHealth::Retention.for(project)).to eq(365)
    project.update!(session_health_retention_days: "")
    expect(SessionHealth::Retention.for(project)).to eq(60)
    [ project, project.organization, Settings::Global.instance ].each do |target|
      [ 0, -1, 366, 1.5 ].each do |days|
        target.session_health_retention_days = days
        expect(target).not_to be_valid
      end
    end
  end

  it "prunes first arrivals without renewing their TTL on a later update and never manufactures a healthy end" do
    sid = SecureRandom.uuid
    travel_to(Time.utc(2026, 10, 1)) { record(sid: sid) }
    travel_to(Time.utc(2026, 10, 30)) do
      record(sid: sid)
      expect(project.health_sessions.sole.status).to eq("ok")
    end
    travel_to(Time.utc(2026, 11, 1, 0, 0, 1)) { described_class.perform_now }
    expect(project.health_sessions.count).to eq(0)
    expect(SessionHealth::Aggregate.where(project_id: project.id).count).to eq(0)
  end

  it "prunes aggregate rows by receipt time rather than producer clock" do
    item = { type: "sessions", value: { release: "retained", environment: nil, started_at: Time.utc(2020), exited: 1, errored: 0, unhandled: 0, crashed: 0, abnormal: 0 } }
    SessionHealth::Ingest::Record.call(project: project, items: [ item ])
    described_class.perform_now
    expect(project.health_aggregates.count).to eq(1)
    travel 31.days do
      described_class.perform_now
      expect(project.health_aggregates.count).to eq(0)
    end
  end
end
