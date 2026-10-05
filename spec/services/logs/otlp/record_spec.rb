# frozen_string_literal: true

require "rails_helper"

RSpec.describe Logs::Otlp::Record do
  let(:project) { create(:project) }
  let(:log) { { "timeUnixNano" => "1780000000123456789", "observedTimeUnixNano" => "1780000001123456799", "severityNumber" => 18, "severityText" => "ERROR2", "traceId" => "a" * 32, "spanId" => "b" * 16, "body" => { "stringValue" => "Failure alice@example.test" } } }

  def attribute(key, value)
    { "key" => key, "value" => { "stringValue" => value } }
  end

  def export(*records)
    { "resourceLogs" => [ { "resource" => { "attributes" => [ attribute("service.name", "checkout") ] }, "scopeLogs" => [ { "scope" => { "name" => "logger" }, "logRecords" => records } ] } ] }
  end

  def record(*records, target: project)
    described_class.call(project: target, payload: export(*records))
  end

  def exception_log(event_id: "c" * 32, uid: "exception-one")
    log.merge("eventName" => "exception", "attributes" => [ attribute("exception.type", "TypeError"), attribute("exception.message", "Failure alice@example.test"), attribute("exception.stacktrace", "at checkout alice@example.test"), attribute("closeyourit.error.event_id", event_id), attribute("log.record.uid", uid) ])
  end

  it "persists exact times and typed snapshots without creating errors from severity" do
    expect(record(log).rejected).to eq(0)
    entry = project.logs_entries.sole
    expect(entry.event_time_unix_nano.to_i.to_s).to eq(log["timeUnixNano"])
    expect(entry.observed_time_unix_nano.to_i.to_s).to eq(log["observedTimeUnixNano"])
    expect(entry).to have_attributes(severity_number: 18, severity_text: "ERROR2", level: "error", span_id: "b" * 16, signal_source: "otlp")
    expect(entry.otlp_payload.keys).to contain_exactly("resource", "resource_schema_url", "scope", "scope_schema_url", "log_record", "diagnostics")
    expect(entry.attributes.to_json).not_to include("alice@example.test")
    expect(project.error_events.count).to eq(0)
  end

  it "keeps identical records without a producer identity distinct" do
    record(log, log)
    record(log)
    expect(project.logs_entries.count).to eq(3)
  end

  it "deduplicates an explicit identity across months without refreshing arrival time and rejects conflicting content" do
    item = log.merge("attributes" => [ attribute("log.record.uid", "unique-one") ])
    travel_to(Time.utc(2026, 7, 31, 23, 59)) { record(item) }
    first = project.logs_entries.sole.created_at
    travel_to(Time.utc(2026, 8, 1)) do
      expect(record(item).rejected).to eq(0)
      expect(record(item.merge("severityText" => "changed"), log).rejected).to eq(1)
    end
    expect(project.logs_entries.count).to eq(2)
    expect(project.logs_entries.find_by!(event_id: "otlp:unique-one").created_at).to eq(first)
  end

  it "diagnoses native identity collisions rather than acknowledging an unstored OTLP record" do
    create(:log_entry, project: project, event_id: "otlp:collision")
    item = log.merge("attributes" => [ attribute("log.record.uid", "collision") ])
    expect(record(item).rejected).to eq(1)
    expect(project.logs_entries.sole.signal_source).to eq("native")
  end

  it "deduplicates Sentry first and OTLP first only by an explicit shared event identity" do
    first = "c" * 32
    second = "d" * 32
    Errors::Ingest::Record.call(project: project, payload: { "event_id" => first, "message" => "Original Sentry event" })
    record(exception_log(event_id: first))
    record(exception_log(event_id: second, uid: "exception-two"))
    Errors::Ingest::Record.call(project: project, payload: { "event_id" => second, "message" => "Later Sentry event" })
    expect(project.error_events.count).to eq(2)
    expect(project.error_groups.sum(:events_count)).to eq(2)
    expect(project.error_events.find_by!(event_id: first).payload["message"]).to eq("Original Sentry event")
    second_event = project.error_events.find_by!(event_id: second)
    expect(second_event).to have_attributes(trace_id: "a" * 32, span_id: "b" * 16, handled: nil)
    expect(second_event.attributes.to_json).not_to include("alice@example.test")
    expect(project.logs_entries.pluck(:error_event_id)).to contain_exactly(first, second)
  end

  it "does not correlate identities across projects or infer error identities from identical contents" do
    other = create(:project)
    item = exception_log
    record(item)
    record(item, target: other)
    unlinked = item.deep_dup
    unlinked["attributes"].reject! { |entry| entry["key"].in?(%w[log.record.uid closeyourit.error.event_id]) }
    record(unlinked, unlinked)
    expect(project.error_events.count).to eq(3)
    expect(other.error_events.count).to eq(1)
    expect(project.error_events.pluck(:event_id) & other.error_events.pluck(:event_id)).to eq([ "c" * 32 ])
  end

  it "preserves unsigned nanosecond maxima and falls back from absent event time to observed time" do
    record(log.merge("timeUnixNano" => "18446744073709551615"))
    expect(project.logs_entries.sole.event_time_unix_nano.to_i).to eq(2**64 - 1)
    record(log.merge("timeUnixNano" => "0"))
    expect(project.logs_entries.order(:created_at).last.occurred_at.to_i).to eq(1_780_000_001)
  end

  it "keeps canonical resource environment and reports a conflict without repeating values in diagnostics" do
    payload = export(log)
    payload["resourceLogs"][0]["resource"]["attributes"].concat([ attribute("deployment.environment.name", "production"), attribute("deployment.environment", "legacy") ])
    described_class.call(project: project, payload: payload)
    entry = project.logs_entries.sole
    expect(entry.environment).to eq("production")
    expect(entry.otlp_payload["diagnostics"]).to eq("environment_conflict" => true)
  end

  it "reuses existing log alert and broadcast behavior only for newly inserted records" do
    item = log.merge("attributes" => [ attribute("log.record.uid", "notify-once") ])
    allow(Logs::Broadcast).to receive(:refresh)
    expect { record(item) }.to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "log_alert"))
    expect { record(item) }.not_to have_enqueued_job(Alerting::EvaluateJob)
    expect(Logs::Broadcast).to have_received(:refresh).once
  end
  it "records an observed SDK source once per newly admitted batch" do
    item = log.merge("attributes" => [ attribute("log.record.uid", "source-once") ])
    payload = export(item)
    payload["resourceLogs"][0]["resource"]["attributes"].concat([ attribute("telemetry.sdk.name", "opentelemetry"), attribute("telemetry.sdk.version", "1.46.0") ])
    2.times { described_class.call(project: project, payload: payload) }
    expect(project.sources.sole).to have_attributes(tool_code: "opentelemetry", version: "1.46.0", events_count: 1)
  end

  it "allows explicit identities to be admitted again once their retained records are pruned" do
    item = log.merge("attributes" => [ attribute("log.record.uid", "retained-only") ])
    record(item)
    original_id = project.logs_entries.sole.id
    project.logs_entries.delete_all
    record(item)
    expect(project.logs_entries.sole.id).not_to eq(original_id)
  end
  it "admits the maximum batch with a single bulk insert and bounded log queries" do
    project
    records = Array.new(1_000) { |index| log.merge("attributes" => [ attribute("log.record.uid", "batch-#{index}") ]) }
    statements = []
    subscriber = ->(_name, _start, _finish, _id, data) { statements << data[:sql] if data[:name] != "SCHEMA" && data[:sql].include?("logs_entries") }
    result = nil
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { result = record(*records) }
    expect(result.rejected).to eq(0)
    expect(project.logs_entries.count).to eq(1_000)
    expect(statements.count { |sql| sql.start_with?("INSERT INTO") }).to eq(1)
    expect(statements.size).to be <= 4
  end
end
