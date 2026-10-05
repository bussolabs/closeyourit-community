# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Native symbolication dispatch" do
  include ActiveJob::TestHelper
  %w[javascript java].each do |platform|
    it "preserves #{platform} reconstruction when the crash report contains only text attachments" do
      project = create(:project)
      event = create(:error_event, project: project, payload: { "platform" => platform }, stacktrace: { "frames" => [] })
      expected = Errors::Symbolication::Resolve.call(event: event)
      project.crash_reports.create!(event_id: event.event_id, manifest: {})
      expect(Errors::Symbolication::Resolve.call(event: event)).to eq(expected)
      expect(expected["kind"]).not_to eq("native")
    end
  end

  it "keeps native platform events explicit when no manifest is available" do
    event = create(:error_event, payload: { "platform" => "native" })
    expect(Errors::Symbolication::Resolve.call(event: event)).to include("kind" => "native", "reason" => "crash_report_unavailable")
  end

  it "does not schedule native processing for a non-native event with text-only attachments" do
    project = create(:project)
    payload = { "event_id" => SecureRandom.hex(16), "platform" => "ruby", "message" => "A handled exception" }
    outcome = Crashes::Record.call(project: project, event: payload, items: [ { header: { "filename" => "notes.txt" }, bytes: "Diagnostic text" } ])
    expect(outcome.report.manifest).to eq({})
    clear_enqueued_jobs
    event = Errors::Ingest::Record.call(project: project, payload: payload).value
    expect(enqueued_jobs.none? { |job| job[:job] == Errors::SymbolicateJob }).to be(true)
    expect(Errors::Symbolication::Native::Source.find(event)).to be_nil
    expect(Errors::Symbolication::Native::Source.available([ event ])).to eq({})
  end
end
