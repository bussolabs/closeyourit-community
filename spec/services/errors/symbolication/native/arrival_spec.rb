# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Native crash arrival ordering" do
  include ActiveJob::TestHelper
  let(:project) { create(:project) }
  let(:payload) { { "event_id" => SecureRandom.hex(16), "platform" => "native", "message" => "Native crash" } }

  def scheduled_ids
    enqueued_jobs.select { |job| job[:job] == Errors::SymbolicateJob }.flat_map { |job| job[:args] }.map { |args| args.fetch("event_id") }
  end

  it "enqueues the retained report when its error arrives later and on idempotent error replay" do
    report = project.crash_reports.create!(event_id: payload.fetch("event_id"), manifest: native_fixture.fetch("raw_report"))
    clear_enqueued_jobs
    result = Errors::Ingest::Record.call(project: project, payload: payload)
    expect(scheduled_ids).to eq([ result.value.id ])
    clear_enqueued_jobs
    Errors::Ingest::Record.call(project: project, payload: payload)
    expect(scheduled_ids).to eq([ result.value.id ])
    expect(report.reload.manifest).to eq(native_fixture.fetch("raw_report"))
  end

  it "requeues the existing error after attachment admission without mutating its payload" do
    result = Errors::Ingest::Record.call(project: project, payload: payload)
    original = result.value.payload.deep_dup
    project.crash_reports.create!(event_id: payload.fetch("event_id"), manifest: native_fixture.fetch("raw_report"))
    clear_enqueued_jobs
    outcome = Crashes::Record.call(project: project, event: payload, items: [ { header: { "filename" => "diagnostic.txt" }, bytes: "Native report is available" } ])
    expect(outcome.accepted).to eq(1)
    expect(scheduled_ids).to eq([ result.value.id ])
    expect(result.value.reload.payload).to eq(original)
  end
end
