# frozen_string_literal: true

require "rails_helper"

RSpec.describe Traces::Ingest::Record, type: :service do
  let(:project) { create(:project) }
  let(:trace_id) { "a" * 32 }
  let(:span_id) { "b" * 16 }
  let(:span) do
    { "traceId" => trace_id, "spanId" => span_id, "name" => "checkout", "kind" => 2,
      "startTimeUnixNano" => "1780000000123456789", "endTimeUnixNano" => "1780000000123456799" }
  end

  def export(*spans)
    { "resourceSpans" => [ { "resource" => { "attributes" => [ { "key" => "service.name", "value" => { "stringValue" => "checkout" } } ] },
                            "scopeSpans" => [ { "scope" => { "name" => "official-test" }, "spans" => spans } ] } ] }
  end

  it "persists exact timestamps and deduplicates repeated delivery without refreshing retention" do
    described_class.call(project: project, payload: export(span))
    stored = project.trace_spans.sole
    expect(stored.start_time_unix_nano.to_i).to eq(1_780_000_000_123_456_789)
    expect(stored.end_time_unix_nano.to_i - stored.start_time_unix_nano.to_i).to eq(10)
    original_arrival = stored.first_received_at
    travel 1.day do
      expect(described_class.call(project: project, payload: export(span)).rejected).to eq(0)
    end
    expect(project.trace_spans.count).to eq(1)
    expect(stored.reload.first_received_at).to eq(original_arrival)
    expect(project.traces.sole.retained_spans_count).to eq(1)
  end

  it "retains orphan children and repairs their observed topology when parents arrive later" do
    child = span.merge("spanId" => "c" * 16, "parentSpanId" => span_id)
    described_class.call(project: project, payload: export(child))
    expect(project.traces.sole.topology).to include(root_present: false, missing_parent_count: 1, completeness: "incomplete")
    described_class.call(project: project, payload: export(span))
    expect(project.traces.sole.topology).to include(root_present: true, missing_parent_count: 0, completeness: "unknown")
  end

  it "rejects conflicting snapshots and never overwrites the first admitted span" do
    described_class.call(project: project, payload: export(span))
    result = described_class.call(project: project, payload: export(span.merge("name" => "conflicting")))
    expect(result.rejected).to eq(1)
    expect(project.trace_spans.sole.name).to eq("checkout")
    expect(project.traces.sole.retained_spans_count).to eq(1)
  end

  it "deduplicates attribute order while preserving event order as part of immutable identity" do
    attrs = [ { "key" => "z", "value" => { "intValue" => "1" } }, { "key" => "a", "value" => { "intValue" => 2 } } ]
    span["attributes"] = attrs
    span["events"] = [ { "name" => "first" }, { "name" => "second" } ]
    described_class.call(project: project, payload: export(span))
    expect(described_class.call(project: project, payload: export(span.merge("attributes" => attrs.reverse))).rejected).to eq(0)
    expect(described_class.call(project: project, payload: export(span.merge("events" => span["events"].reverse))).rejected).to eq(1)
  end

  it "allows identical external IDs in separate projects and enforces tenant identity at the database boundary" do
    other = create(:project)
    described_class.call(project: project, payload: export(span))
    described_class.call(project: other, payload: export(span))
    expect(project.trace_spans.count).to eq(1)
    expect(other.trace_spans.count).to eq(1)
    expect do
      Traces::Span.transaction(requires_new: true) do
        project.trace_spans.sole.update_columns(trace_record_id: other.traces.sole.id)
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "counts missing parent identities once when several children reference the same parent" do
    children = %w[c d].map { |id| span.merge("spanId" => id * 16, "parentSpanId" => span_id) }
    described_class.call(project: project, payload: export(*children))
    expect(project.traces.sole.topology).to include(missing_parent_count: 1, root_present: false)
  end

  it "resolves resource environment precedence and keeps missing identities unknown" do
    described_class.call(project: project, payload: export(span))
    record = project.trace_spans.sole
    expect(record.resource_identity).to include(service_name: "checkout", environment: nil, environment_conflict: false)
    [ [ nil, "legacy", "legacy", false ], [ "canonical", "legacy", "canonical", true ], [ "same", "same", "same", false ] ].each do |canonical, legacy, expected, conflict|
      record.resource = { "attributes" => [
        (canonical && { "key" => "deployment.environment.name", "value" => { "stringValue" => canonical } }),
        { "key" => "deployment.environment", "value" => { "stringValue" => legacy } }
      ].compact }
      expect(record.resource_identity).to include(environment: expected, environment_conflict: conflict)
    end
  end

  it "never persists sensitive free text, attributes or derived service names" do
    token = "cyi_" + "s" * 40
    span["name"] = "request #{token} alice@example.test"
    span["attributes"] = [ { "key" => "db.query.text", "value" => { "stringValue" => "private SQL bind" } } ]
    span["status"] = { "message" => "Bearer hidden-credential" }
    span["events"] = [ { "name" => "alice@example.test" } ]
    data = export(span)
    data["resourceSpans"][0]["resource"]["attributes"][0]["value"]["stringValue"] = "alice@example.test"
    described_class.call(project: project, payload: data)
    text = project.trace_spans.sole.attributes.to_json
    expect(text).not_to include(token, "alice@example.test", "private SQL bind", "hidden-credential")
    expect(text).to include("[FILTERED]")
  end
end
