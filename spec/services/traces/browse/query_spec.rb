# frozen_string_literal: true

require "rails_helper"

RSpec.describe Traces::Browse::Query do
  let(:project) { create(:project) }
  let(:trace_id) { "a" * 32 }

  def admit(id:, service: "checkout", environment: "production", version: "v1", start: 1_780_000_000_000_000_001, finish: nil, status: 0, owner: project, extra: [])
    attrs = { "service.name" => service, "deployment.environment.name" => environment, "service.version" => version }
      .filter_map { |key, value| { "key" => key, "value" => { "stringValue" => value } } unless value.nil? } + extra
    span = { "traceId" => trace_id, "spanId" => id * 16, "name" => "checkout-#{id}", "startTimeUnixNano" => start.to_s,
      "endTimeUnixNano" => (finish || start + 10).to_s, "status" => { "code" => status } }
    Traces::Ingest::Record.call(project: owner, payload: { "resourceSpans" => [ { "resource" => { "attributes" => attrs }, "scopeSpans" => [ { "spans" => [ span ] } ] } ] })
  end

  def query(**params)
    described_class.call(scope: project.traces, params: params)
  end

  it "requires service, environment and typed version on the same span" do
    admit(id: "b", service: "edge", environment: "production", version: "v1")
    admit(id: "c", service: "worker", environment: "staging", version: "v2")
    expect(query(service: "edge", environment: "staging").total).to eq(0)
    expect(query(service: "edge", environment: "production", version: "v1").total).to eq(1)
    expect(query(version: "1").total).to eq(0)
  end

  it "never falls back to a legacy environment when a canonical empty environment exists" do
    admit(id: "b", environment: "", extra: [ { "key" => "deployment.environment", "value" => { "stringValue" => "legacy" } } ])
    expect(query(environment: "legacy").total).to eq(0)
    expect(query(environment: "").total).to eq(1)
  end

  it "keeps exact observed duration beyond float precision and does not add parallel spans" do
    origin = 1_780_000_000_000_000_001
    admit(id: "b", start: origin, finish: origin + 9_007_199_254_740_993)
    admit(id: "c", start: origin + 1, finish: origin + 2)
    record = query.records.sole
    expect(record[:observed_duration_ns].to_i).to eq(9_007_199_254_740_993)
    expect(query(min_duration_ms: "9007199254.740994").total).to eq(0)
    expect(query(max_duration_ms: "9007199254.740993").total).to eq(1)
  end

  it "distinguishes zero duration, mixed statuses, errors and no recorded spans" do
    admit(id: "b", start: 100, finish: 100, status: 1)
    expect(query.records.sole[:observed_status]).to eq("ok")
    expect(query.records.sole[:observed_duration_ns].to_i).to eq(0)
    admit(id: "c", status: 0)
    expect(query(status: "mixed").total).to eq(1)
    admit(id: "d", status: 2)
    expect(query(status: "error").total).to eq(1)
    expect(query(status: "mixed").total).to eq(0)
    project.trace_spans.delete_all
    expect(query(q: "").records.sole[:observed_status]).to eq("unknown")
    expect(query.records.sole[:observed_duration_ns]).to be_nil
    expect(query(q: trace_id).total).to eq(1)
  end

  it "scopes before aggregation and keeps same external IDs separate across projects" do
    admit(id: "b")
    other = create(:project)
    admit(id: "b", owner: other, service: "foreign")
    expect(query(service: "foreign").total).to eq(0)
    expect(query.records.map(&:project_id)).to eq([ project.id ])
    expect(described_class.call(scope: project.traces.none, params: {}).total).to eq(0)
  end

  it "paginates with stable ordering and rejects invalid scalar filters and reversed durations" do
    3.times { |i| project.traces.create!(trace_id: (i + 1).to_s(16).rjust(32, "0"), first_received_at: Time.current, last_received_at: Time.current) }
    first = query(per: "1", page: "1")
    second = query(per: "1", page: "2")
    expect(first.total).to eq(3)
    expect(first.records.sole.id).not_to eq(second.records.sole.id)
    [ { service: [] }, { q: {} }, { min_duration_ms: "NaN" }, { min_duration_ms: "2", max_duration_ms: "1" }, { sort: "DROP TABLE" } ].each do |params|
      expect { query(**params) }.to raise_error(Traces::Browse::Invalid)
    end
  end
end
