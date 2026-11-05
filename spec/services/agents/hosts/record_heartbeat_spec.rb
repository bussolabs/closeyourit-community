# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Hosts::RecordHeartbeat, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYRA") }
  let(:host) { create(:agent_host, organization:) }

  def payload(overrides = {})
    {
      host_id: host.id,
      automator_version: "0.3.1",
      platform: "linux",
      arch: "arm64",
      runtimes: [ { name: "codex", present: true, version: nil, required: true } ],
      repositories: [ "CYRA" ],
      running: 0,
      slots: 1,
      host_status: "idle",
      active_runs: [],
      expected_interval_minutes: 2,
      grace_minutes: 1
    }.merge(overrides)
  end

  # CYRA-823 — chi sta guardando la scheda di questa macchina deve vederla cambiare senza ricaricare.
  # Il battito è il momento in cui l'attività cambia davvero: è da lì che parte l'avviso.
  describe "avviso a chi sta guardando la scheda" do
    before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

    it "un battito che aggiorna lo snapshot avvisa chi ha la scheda aperta" do
      expect { described_class.call(project:, payload: payload(running: 1), at: Time.current) }
        .to have_broadcasted_to(Realtime::Streams.agent_host(host))
        .with(a_string_including('action="refresh_frame"'))
    end

    # Un battito vecchio arrivato in ritardo non cambia niente sullo schermo: avvisare sarebbe
    # chiedere a ogni scheda aperta di ri-chiedere una pagina identica a quella che ha già.
    it "un battito più vecchio dello snapshot non avvisa nessuno" do
      adesso = Time.utc(2026, 7, 13, 20, 2)
      described_class.call(project:, payload: payload(running: 1), at: adesso)

      expect { described_class.call(project:, payload: payload(running: 0), at: adesso - 1.minute) }
        .not_to have_broadcasted_to(Realtime::Streams.agent_host(host))
    end
  end

  it "un heartbeat arrivato tardi non sovrascrive uno snapshot più recente" do
    newer_at = Time.utc(2026, 7, 13, 20, 2)
    older_at = newer_at - 1.minute

    newer = described_class.call(project:, payload: payload(host_status: "busy", running: 1), at: newer_at)
    older = described_class.call(project:, payload: payload(host_status: "idle", running: 0), at: older_at)

    expect(newer).to be_ok
    expect(older).to be_ok
    expect(host.reload).to have_attributes(last_heartbeat_at: newer_at, host_status: "busy", running: 1)
  end

  it "limita gli array per impedire payload host non bounded" do
    result = described_class.call(
      project:, payload: payload(repositories: Array.new(101) { |index| "R#{index}" }), at: Time.current
    )

    expect(result).to be_err
    expect(result.error.code).to eq("R422-AGENT-004")
    expect(host.reload.last_heartbeat_at).to be_nil
  end

  it "rifiuta telemetria che prova a cambiare la piattaforma in non Linux" do
    result = described_class.call(project:, payload: payload(platform: "darwin"), at: Time.current)

    expect(result).to be_err
    expect(result.error).to have_attributes(code: "R422-AGENT-004", status: :unprocessable_content)
    expect(result.error.details).to include("platform" => [ "non valido" ])
    expect(host.reload).to have_attributes(platform: "linux", last_heartbeat_at: nil)
  end

  it "rifiuta il battito di un host storico non Linux" do
    host.update_column(:platform, "darwin")

    result = described_class.call(project:, payload: { host_id: host.id }, at: Time.current)

    expect(result).to be_err
    expect(result.error).to have_attributes(code: "R403-AGENT-007", status: :forbidden)
    expect(host.reload.last_heartbeat_at).to be_nil
  end

  it "accetta il payload minimo e normalizza nil, interi stringa e campi nullable" do
    minimal = described_class.call(project:, payload: { host_id: host.id }, at: Time.current)
    expect(minimal).to be_ok

    active_run = {
      ticket: "CYRA-1", run_id: "run-1", phase: nil, runtime: nil,
      started_at: nil, updated_at: nil, lease_expires_at: nil,
      lease_health: "active", stalled: false
    }
    normalized = described_class.call(
      project:,
      payload: payload(
        automator_version: nil, running: "1", slots: "2",
        runtimes: [], repositories: [], active_runs: [ active_run ]
      ),
      at: Time.current
    )

    expect(normalized).to be_ok
    expect(host.reload).to have_attributes(automator_version: nil, running: 1, slots: 2)
    expect(host.active_runs).to eq([ active_run.deep_stringify_keys ])
  end

  it "rifiuta scalar, enum, runtime, repository e run malformati con errori puntuali" do
    malformed = described_class.call(
      project:,
      payload: payload(
        platform: "", running: "not-an-integer", host_status: "offline",
        runtimes: [ "codex", {} ], repositories: [ nil ], active_runs: [ "run", {} ]
      ),
      at: Time.current
    )

    expect(malformed).to be_err
    expect(malformed.error.details.keys).to include(
      "platform", "running", "host_status", "runtimes.0", "runtimes.1",
      "repositories.0", "active_runs.0", "active_runs.1"
    )

    non_arrays = described_class.call(
      project:,
      payload: payload(runtimes: {}, repositories: "CYRA", active_runs: {}),
      at: Time.current
    )
    expect(non_arrays).to be_err
    expect(non_arrays.error.details.keys).to include("runtimes", "repositories", "active_runs")
  end

  it "rejects run timestamps that are not ISO8601 strings" do
    base_run = {
      ticket: "CYRA-1", run_id: "run-1", phase: "implementing", runtime: "claude",
      updated_at: nil, lease_expires_at: nil, lease_health: "active", stalled: false
    }
    result = described_class.call(
      project:,
      payload: payload(
        active_runs: [ base_run.merge(started_at: 123), base_run.merge(run_id: "run-2", started_at: "nope") ]
      ),
      at: Time.current
    )

    expect(result).to be_err
    expect(result.error.details.keys).to include("active_runs.0", "active_runs.1")
  end

  # CYRA-1056 — a deleted project left in the host map must not drop the whole heartbeat.
  it "drops project keys unknown to the organization and still records the heartbeat" do
    create(:project, key: "OTHR")
    at = Time.current

    result = described_class.call(project:, payload: payload(repositories: [ "CYRA", "NOPE", "OTHR" ]), at:)

    expect(result).to be_ok
    expect(host.reload).to have_attributes(repositories: [ "CYRA" ], last_heartbeat_at: be_within(1.second).of(at))
  end

  # CYRA-1178 — the Automator hang watchdog: while the event loop is blocked it sends a reduced heartbeat
  # (host_id, automator_version, hang), then one heartbeat saying how the hang ended.
  describe "hang" do
    let(:started_at) { "2026-11-03T10:00:00Z" }
    let(:hung) { { state: "hung", started_at:, duration_seconds: 180 } }

    it "stores the report of a reduced heartbeat with the time it arrived" do
      at = Time.current
      reduced = { host_id: host.id, automator_version: "0.48.0", hang: hung }
      result = described_class.call(project:, payload: reduced, at:)

      expect(result).to be_ok
      expect(host.reload.hang).to eq(
        "state" => "hung", "started_at" => started_at, "duration_seconds" => 180, "resumed_at" => nil,
        "reported_at" => at.utc.iso8601(6)
      )
      expect(host.last_heartbeat_at).to be_within(1.second).of(at)
    end

    it "stores how the hang ended and drops unknown keys" do
      ended = hung.merge(state: "resumed", duration_seconds: 240, resumed_at: "2026-11-03T10:04:00Z", token: "secret")
      result = described_class.call(project:, payload: payload(hang: ended), at: Time.current)

      expect(result).to be_ok
      expect(host.reload.hang).to include("state" => "resumed", "resumed_at" => "2026-11-03T10:04:00Z")
      expect(host.hang.keys).to contain_exactly("state", "started_at", "duration_seconds", "resumed_at", "reported_at")
    end

    it "keeps the previous report when an older automator sends no hang" do
      described_class.call(project:, payload: payload(hang: hung), at: 2.minutes.ago)
      described_class.call(project:, payload: payload, at: 1.minute.ago)

      expect(host.reload.hang).to include("state" => "hung")
    end

    it "leaves the column empty for an automator that never reports a hang" do
      described_class.call(project:, payload: payload, at: Time.current)

      expect(host.reload.hang).to be_nil
    end

    it "rejects a malformed report without touching the host" do
      [ hung.merge(state: "frozen"), hung.merge(started_at: "yesterday"), hung.merge(duration_seconds: -1),
        hung.merge(duration_seconds: "abc"), hung.merge(resumed_at: "soon"), hung.except(:started_at), "hung" ]
        .each do |report|
          result = described_class.call(project:, payload: payload(hang: report), at: Time.current)

          expect(result).to be_err
          expect(result.error.details.keys).to include("hang")
          expect(host.reload.hang).to be_nil
        end
    end
  end

  # CYRA-999 — the reasons the machine last stopped before taking work (Automator CYAU-116).
  describe "last_stops" do
    let(:stop) { { action: "lab", state: "waiting", reason: "empty ticket queue for LAB" } }

    it "stores the stops sent with the heartbeat" do
      result = described_class.call(project:, payload: payload(last_stops: [ stop ]), at: Time.current)

      expect(result).to be_ok
      expect(host.reload.last_stops).to eq([ { "action" => "lab", "state" => "waiting", "reason" => "empty ticket queue for LAB" } ])
    end

    it "keeps the previous stops when the field is absent and clears them on an empty list" do
      described_class.call(project:, payload: payload(last_stops: [ stop ]), at: 2.minutes.ago)
      described_class.call(project:, payload: payload, at: 1.minute.ago)
      expect(host.reload.last_stops.size).to eq(1)

      described_class.call(project:, payload: payload(last_stops: []), at: Time.current)
      expect(host.reload.last_stops).to eq([])
    end

    it "drops unknown keys and shortens an overlong reason instead of losing the heartbeat" do
      result = described_class.call(
        project:, payload: payload(last_stops: [ stop.merge(reason: "x" * 2_000, token: "secret") ]), at: Time.current
      )

      expect(result).to be_ok
      saved = host.reload.last_stops.first
      expect(saved.keys).to contain_exactly("action", "state", "reason")
      expect(saved["reason"].length).to eq(described_class::MAX_STOP_REASON_LENGTH)
    end

    it "rejects malformed stops and more stops than the Automator ever sends" do
      malformed = described_class.call(
        project:, payload: payload(last_stops: [ stop.merge(state: "ready"), "lab", stop.merge(action: "") ]), at: Time.current
      )
      expect(malformed).to be_err
      expect(malformed.error.details.keys).to include("last_stops.0", "last_stops.1", "last_stops.2")

      too_many = described_class.call(project:, payload: payload(last_stops: Array.new(6) { stop }), at: Time.current)
      expect(too_many).to be_err
      expect(too_many.error.details.keys).to include("last_stops")
    end

    it "rejects invalid reason types and content without replacing previous stops" do
      described_class.call(project:, payload: payload(last_stops: [ stop ]), at: Time.current)
      previous = host.reload.last_stops

      [ nil, 42, "", " \t", "invalid\0reason" ].each do |reason|
        result = described_class.call(project:, payload: payload(last_stops: [ stop.merge(reason:) ]), at: Time.current)

        expect(result).to be_err
        expect(result.error.details.keys).to include("last_stops.0")
        expect(host.reload.last_stops).to eq(previous)
      end
    end

    it "rejects a non-array stop list without treating it as a clear request" do
      described_class.call(project:, payload: payload(last_stops: [ stop ]), at: Time.current)
      previous = host.reload.last_stops

      [ nil, {}, "waiting" ].each do |stops|
        result = described_class.call(project:, payload: payload(last_stops: stops), at: Time.current)

        expect(result).to be_err
        expect(result.error.details.keys).to include("last_stops")
        expect(host.reload.last_stops).to eq(previous)
      end
    end

    it "accepts exactly five stops and preserves their order" do
      stops = Array.new(5) { |index| stop.merge(action: "queue-#{index}") }
      result = described_class.call(project:, payload: payload(last_stops: stops), at: Time.current)

      expect(result).to be_ok
      expect(host.reload.last_stops.pluck("action")).to eq(stops.pluck(:action))
    end
  end

  # CYRA-1177 — remaining quota and pause of each engine (Automator CYAU-275). Unknown stays null, never 0.
  describe "agent_quota" do
    let(:claude) { { runtime: "claude", remaining_percent: 42, resets_at: "2026-11-03T15:00:00.000Z", paused_until: nil } }
    let(:codex) { { runtime: "codex", remaining_percent: nil, resets_at: nil, paused_until: "2026-11-03T12:00:00.000Z" } }

    it "stores one entry per engine, keeping unknown values null" do
      result = described_class.call(project:, payload: payload(agent_quota: [ claude, codex ]), at: Time.current)

      expect(result).to be_ok
      expect(host.reload.agent_quota).to eq([
        { "runtime" => "claude", "remaining_percent" => 42, "resets_at" => "2026-11-03T15:00:00.000Z", "paused_until" => nil },
        { "runtime" => "codex", "remaining_percent" => nil, "resets_at" => nil, "paused_until" => "2026-11-03T12:00:00.000Z" }
      ])
    end

    it "accepts a heartbeat without the field and keeps the previous report" do
      described_class.call(project:, payload: payload(agent_quota: [ claude ]), at: 2.minutes.ago)
      result = described_class.call(project:, payload: payload, at: 1.minute.ago)

      expect(result).to be_ok
      expect(host.reload.agent_quota.size).to eq(1)
    end

    it "leaves a machine that never reported with an empty report" do
      expect(described_class.call(project:, payload: payload, at: Time.current)).to be_ok
      expect(host.reload.agent_quota).to eq([])
    end

    it "accepts the bounds and a fractional percent" do
      quota = [ claude.merge(remaining_percent: 0), codex.merge(remaining_percent: 100) ]
      expect(described_class.call(project:, payload: payload(agent_quota: quota), at: 1.minute.ago)).to be_ok

      fractional = described_class.call(project:, payload: payload(agent_quota: [ claude.merge(remaining_percent: 12.5) ]), at: Time.current)
      expect(fractional).to be_ok
      expect(host.reload.agent_quota.first["remaining_percent"]).to eq(12.5)
    end

    it "drops unknown keys and engines it does not know" do
      quota = [ claude.merge(token: "secret"), { runtime: "gemini", remaining_percent: 10, resets_at: nil, paused_until: nil } ]
      result = described_class.call(project:, payload: payload(agent_quota: quota), at: Time.current)

      expect(result).to be_ok
      expect(host.reload.agent_quota).to eq([
        { "runtime" => "claude", "remaining_percent" => 42, "resets_at" => "2026-11-03T15:00:00.000Z", "paused_until" => nil }
      ])
    end

    it "rejects out-of-range or non-numeric percents without replacing the previous report" do
      described_class.call(project:, payload: payload(agent_quota: [ claude ]), at: 1.minute.ago)
      previous = host.reload.agent_quota

      [ -1, 100.1, "42", true ].each do |remaining_percent|
        result = described_class.call(project:, payload: payload(agent_quota: [ claude.merge(remaining_percent:) ]), at: Time.current)

        expect(result).to be_err
        expect(result.error.details.keys).to include("agent_quota.0")
        expect(host.reload.agent_quota).to eq(previous)
      end
    end

    it "rejects malformed timestamps, entries, duplicates and lists" do
      bad_time = described_class.call(project:, payload: payload(agent_quota: [ claude.merge(resets_at: "tomorrow"), codex.merge(paused_until: 42) ]), at: Time.current)
      expect(bad_time.error.details.keys).to include("agent_quota.0", "agent_quota.1")

      not_a_hash = described_class.call(project:, payload: payload(agent_quota: [ "claude" ]), at: Time.current)
      expect(not_a_hash.error.details.keys).to include("agent_quota.0")

      duplicate = described_class.call(project:, payload: payload(agent_quota: [ claude, claude ]), at: Time.current)
      expect(duplicate.error.details.keys).to include("agent_quota.1")

      [ nil, {}, "claude", Array.new(described_class::MAX_AGENT_QUOTA_ENTRIES + 1) { claude } ].each do |quota|
        result = described_class.call(project:, payload: payload(agent_quota: quota), at: Time.current)
        expect(result).to be_err
        expect(result.error.details.keys).to include("agent_quota")
      end
    end
  end
end
