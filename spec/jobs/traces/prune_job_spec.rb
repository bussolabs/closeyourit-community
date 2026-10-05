# frozen_string_literal: true

require "rails_helper"

RSpec.describe Traces::PruneJob, type: :job do
  let(:project) { create(:project) }
  let(:payload) do
    { "resourceSpans" => [ { "scopeSpans" => [ { "spans" => [ { "traceId" => "a" * 32, "spanId" => "b" * 16, "startTimeUnixNano" => "1", "endTimeUnixNano" => "2" } ] } ] } ] }
  end

  it "prunes by first arrival and marks surviving traces incomplete before removing empty traces" do
    travel_to 20.days.ago do
      Traces::Ingest::Record.call(project: project, payload: payload)
    end
    child = payload.deep_dup
    child["resourceSpans"][0]["scopeSpans"][0]["spans"][0].merge!("spanId" => "c" * 16, "parentSpanId" => "b" * 16)
    Traces::Ingest::Record.call(project: project, payload: child)
    Traces::Ingest::Record.call(project: project, payload: payload)
    described_class.perform_now
    trace = project.traces.sole
    expect(trace.retained_spans_count).to eq(1)
    expect(trace.expired_spans_count).to eq(1)
    expect(trace.topology).to include(completeness: "incomplete", root_present: false, missing_parent_count: 1)
    travel 15.days do
      described_class.perform_now
      expect(project.traces.count).to eq(0)
      expect(project.trace_spans.count).to eq(0)
    end
  end

  it "resolves project then organization then global retention and validates bounds" do
    Settings::Global.instance.update!(traces_retention_days: 12)
    expect(Traces::Retention.for(project)).to eq(12)
    project.organization.update!(traces_retention_days: 30)
    expect(Traces::Retention.for(project)).to eq(30)
    project.update!(traces_retention_days: 365)
    expect(Traces::Retention.for(project)).to eq(365)
    [ project, project.organization, Settings::Global.instance ].each do |model|
      [ 0, 366, 1.5, "invalid" ].each do |invalid|
        model.traces_retention_days = invalid
        expect(model).not_to be_valid
      end
    end
  end
end
