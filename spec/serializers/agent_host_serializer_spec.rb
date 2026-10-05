# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentHostSerializer do
  it "espone lo stato online quando l'host è vivo e idle, poi offline a heartbeat scaduto" do
    heartbeat_at = Time.utc(2026, 7, 13, 20, 0)
    host = create(
      :agent_host,
      last_heartbeat_at: heartbeat_at,
      heartbeat_expected_interval_minutes: 2,
      heartbeat_grace_minutes: 1,
      host_status: "idle",
      active_runs: [ { "ticket" => "CYRA-99", "stalled" => false } ]
    )

    travel_to(heartbeat_at + 2.minutes + 59.seconds) do
      json = JSON.parse(described_class.new(host.reload).serialize)
      expect(json["activity_status"]).to eq("online")
      expect(json["online"]).to be(true)
      expect(json.dig("active_runs", 0, "stalled")).to be(false)
    end

    travel_to(heartbeat_at + 3.minutes + 1.second) do
      json = JSON.parse(described_class.new(host.reload).serialize)
      expect(json["activity_status"]).to eq("offline")
      expect(json["online"]).to be(false)
      expect(json.dig("active_runs", 0, "stalled")).to be(true)
      expect(host.reload.active_runs.dig(0, "stalled")).to be(false)
    end
  end

  it "espone busy, waiting e recovery_required senza query per-riga" do
    now = Time.utc(2026, 7, 13, 20, 0)
    hosts = %w[busy waiting recovery_required].map do |status|
      create(:agent_host, last_heartbeat_at: now, host_status: status)
    end
    loaded = Agents::Host.where(id: hosts).load

    travel_to(now) do
      queries = captured_sql do
        statuses = loaded.map { |host| JSON.parse(described_class.new(host).serialize).fetch("activity_status") }
        expect(statuses).to match_array(%w[busy waiting recovery_required])
      end
      expect(queries).to be_empty
    end
  end

  it "ignora active run legacy malformate senza causare errori quando l'host è offline" do
    heartbeat_at = Time.utc(2026, 7, 13, 20, 0)
    host = create(:agent_host, last_heartbeat_at: heartbeat_at)
    host.update_column(:active_runs, [ "invalid", { "ticket" => "CYRA-99", "stalled" => false } ])

    travel_to(heartbeat_at + 2.hours) do
      json = JSON.parse(described_class.new(host.reload).serialize)
      expect(json["active_runs"]).to eq([ { "ticket" => "CYRA-99", "stalled" => true } ])
    end
  end
end
