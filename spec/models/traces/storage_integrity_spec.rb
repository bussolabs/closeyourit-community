# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Trace storage integrity", type: :model do
  let(:project) { create(:project) }
  let(:wire_span) do
    { "traceId" => "a" * 32, "spanId" => "b" * 16, "name" => "checkout",
      "startTimeUnixNano" => "1780000000123456789", "endTimeUnixNano" => "1780000000123456799" }
  end

  def ingest(span = wire_span)
    Traces::Ingest::Record.call(project:, payload: { "resourceSpans" => [ { "scopeSpans" => [ { "spans" => [ span ] } ] } ] })
    project.trace_spans.sole
  end

  def copied_attributes(record)
    record.attributes.except("id").merge("span_id" => "c" * 16)
  end

  it "rejects a cross-project trace reference even when model validation is bypassed" do
    span = ingest
    other = create(:project)
    attributes = copied_attributes(span).merge("project_id" => other.id)
    expect do
      Traces::Span.transaction(requires_new: true) { Traces::Span.insert_all!([ attributes ]) }
    end.to raise_error(ActiveRecord::InvalidForeignKey, /traces_spans_tenant_identity/)
    expect(other.trace_spans.count).to eq(0)
  end

  it "keeps the natural identity unique across arrival months" do
    span = ingest
    attributes = copied_attributes(span).merge("span_id" => span.span_id, "first_received_at" => 2.months.from_now)
    expect do
      Traces::Span.transaction(requires_new: true) { Traces::Span.insert_all!([ attributes ]) }
    end.to raise_error(ActiveRecord::RecordNotUnique, /traces_spans_identity/)
    expect(project.trace_spans.count).to eq(1)
  end

  it "preserves the largest uint64 timestamp without floating point conversion" do
    span = ingest(wire_span.merge("startTimeUnixNano" => "18446744073709551614", "endTimeUnixNano" => "18446744073709551615"))
    expect(span.start_time_unix_nano.to_i).to eq((2**64) - 2)
    expect(span.end_time_unix_nano.to_i).to eq((2**64) - 1)
    expect(span.end_time_unix_nano - span.start_time_unix_nano).to eq(1)
  end

  it "enforces global retention bounds at the database boundary" do
    settings = Settings::Global.instance
    expect do
      Settings::Global.transaction(requires_new: true) { settings.update_column(:traces_retention_days, 0) }
    end.to raise_error(ActiveRecord::StatementInvalid, /settings_valid_trace_retention/)
    expect(settings.reload.traces_retention_days).to eq(14)
  end

  it "cascades project deletion to both trace tables" do
    span = ingest
    trace_id = span.trace_record_id
    project.delete
    expect(Traces::Span.exists?(span.id)).to be(false)
    expect(Traces::Trace.exists?(trace_id)).to be(false)
  end
end
