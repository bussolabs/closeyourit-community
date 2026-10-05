# frozen_string_literal: true

require "rails_helper"

RSpec.describe Traces::Browse::Related do
  let(:project) { create(:project) }
  let(:trace) { project.traces.create!(trace_id: "a" * 32, first_received_at: Time.current, last_received_at: Time.current) }

  it "combines direct and explicit log correlations without duplicates or cross-project matches" do
    direct = create(:error_event, project: project, group: create(:error_group, project: project), trace_id: trace.trace_id, span_id: "b" * 16)
    indirect = create(:error_event, project: project, group: create(:error_group, project: project))
    [ direct, indirect ].each { |event| create(:log_entry, project: project, trace_id: trace.trace_id, span_id: "b" * 16, error_event_id: event.event_id) }
    create(:log_entry, project: project, trace_id: trace.trace_id, span_id: "c" * 16)
    foreign = create(:project)
    create(:log_entry, project: foreign, trace_id: trace.trace_id, error_event_id: indirect.event_id)
    create(:error_event, group: create(:error_group, project: foreign), trace_id: trace.trace_id)
    result = described_class.call(project: project, trace: trace, span_id: "b" * 16)
    expect(result.logs.total).to eq(2)
    expect(result.errors.records.map(&:id)).to contain_exactly(direct.id, indirect.id)
    expect(indirect.reload.trace_id).to be_nil
    expect(described_class.call(project: project, trace: trace, span_id: "c" * 16).errors.total).to eq(0)
    expect { described_class.call(project: foreign, trace: trace) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "paginates related records independently and bounds message projection" do
    13.times { create(:log_entry, project: project, trace_id: trace.trace_id, message: "x" * 1024) }
    result = described_class.call(project: project, trace: trace, logs_page: 2)
    expect(result.logs.total).to eq(13)
    expect(result.logs.records.sole.message.length).to eq(512)
    expect(result.errors.total).to eq(0)
  end
end
