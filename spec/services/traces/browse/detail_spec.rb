# frozen_string_literal: true

require "rails_helper"

RSpec.describe Traces::Browse::Detail do
  let(:project) { create(:project) }

  def admit(owner = project, name: "operation", count: 3)
    spans = (1..count).map do |i|
      { "traceId" => "a" * 32, "spanId" => i.to_s(16).rjust(16, "0"), "parentSpanId" => i == 1 ? nil : "1".rjust(16, "0"),
        "name" => name, "startTimeUnixNano" => (1_780_000_000_000_000_000 + i).to_s, "endTimeUnixNano" => (1_780_000_000_000_000_000 + 2 * i).to_s }.compact
    end
    Traces::Ingest::Record.call(project: owner, payload: { "resourceSpans" => [ { "scopeSpans" => [ { "spans" => spans } ] } ] })
    owner.traces.sole
  end

  it "keeps global extent and a received parent outside the page while selecting an exact off-page span" do
    trace = admit
    value = described_class.call(scope: project.traces, id: trace.id, page: 2, per: 1, span_id: "3".rjust(16, "0"))
    expect(value.pagination.total).to eq(3)
    expect(value.pagination.records.sole[:observed_parent_present]).to be(true)
    expect(value.pagination.records.sole.resource).to eq(project.trace_spans.first.resource)
    expect(value.selected.span_id).to eq("3".rjust(16, "0"))
    expect(value.extent.map(&:to_i)).to eq([ 1_780_000_000_000_000_001, 1_780_000_000_000_000_006 ])
    expect(value.trace.topology).to include(root_present: true, missing_parent_count: 0, completeness: "unknown")
  end

  it "never resolves a hidden trace or foreign span by external identity" do
    trace = admit
    other = admit(create(:project))
    expect { described_class.call(scope: project.traces, id: other.id) }.to raise_error(ActiveRecord::RecordNotFound)
    expect { described_class.call(scope: project.traces, id: trace.id, span_id: "f" * 16) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "clamps page size before offsets and never skips spans" do
    trace = admit(count: 101)
    first = described_class.call(scope: project.traces, id: trace.id, per: 150)
    second = described_class.call(scope: project.traces, id: trace.id, per: 150, page: 2)
    expect(first.pagination.per).to eq(50)
    expect(second.pagination.records.size).to eq(50)
    expect(second.pagination.records.first.span_id).to eq(51.to_s(16).rjust(16, "0"))
    expect(first.pagination.records.map(&:id) & second.pagination.records.map(&:id)).to be_empty
    expect { described_class.call(scope: project.traces, id: "-" * 36) }.to raise_error(Traces::Browse::Invalid)
  end

  it "rejects an oversized selected payload before hydration" do
    trace = admit
    project.trace_spans.where(span_id: "1".rjust(16, "0")).update_all(payload: { "oversized" => "x" * 6.megabytes })
    expect { described_class.call(scope: project.traces, id: trace.id) }.to raise_error(Traces::Browse::Invalid, /byte budget/)
  end
end
