# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Native symbolication ownership" do
  let(:project) { create(:project) }
  let(:event) { create(:error_event, project: project, group: create(:error_group, project: project), payload: { "platform" => "native" }) }
  let(:report) { project.crash_reports.create!(event_id: event.event_id, manifest: native_fixture.fetch("raw_report")) }

  def read
    Errors::Symbolication::Read.call(events: [ event ]).fetch([ project.id, event.id, event.created_at ])
  end

  it "resolves actual minidump frames without mutating received evidence and invalidates deleted dependencies" do
    original = report.manifest.deep_dup
    artifact = upload_native(project)
    Errors::Symbolication::Record.call(event: event)
    value = read
    expect(value).to include("kind" => "native", "status" => "partial")
    expect(value.fetch("frames").size).to eq(original.fetch("threads").sum { |thread| thread.fetch("frames").size })
    matched = value.fetch("frames").select { |frame| frame["artifact_id"] == artifact.id && frame["thread_index"] == original.fetch("crash_info").fetch("crashing_thread") }
    expect(matched.size).to eq(native_fixture.fetch("frames").size)
    matched.zip(native_fixture.fetch("frames")).each do |actual, expected|
      expect(actual).to include("instruction" => expected.fetch("instruction"), "module_offset" => expected.fetch("raw").fetch("module_offset"), "trust" => expected.fetch("trust"), "locations" => expected.fetch("locations"))
    end
    expect(report.reload.manifest).to eq(original)
    expect(value.fetch("native")).to include("report_id" => report.id, "manifest_sha256" => Errors::Symbolication::Native::Source.digest(original))
    expect(Artifacts::Reference.where(native_symbol_id: artifact.id).count).to eq(1)
    artifact.destroy!
    expect(read).to include("kind" => "native", "reason" => "artifact_deleted", "frames" => [])
    upload_native(project)
    Errors::Symbolication::Record.call(event: event)
    report.destroy!
    expect(Errors::Symbolication.where(event_id: event.id)).to be_empty
    expect(read).to include("reason" => "crash_report_unavailable", "frames" => [])
    expect(event.reload.payload).to eq("platform" => "native")
  end

  it "hides a report immediately after retention expires, before physical collection" do
    report
    artifact = upload_native(project)
    Errors::Symbolication::Record.call(event: event)
    report.update!(created_at: 31.days.ago)
    expect(read).to include("reason" => "crash_report_unavailable")
    expect(artifact.reload).to be_present
    Artifacts::PruneJob.perform_now(project_id: project.id)
    expect(Errors::Symbolication.where(event_id: event.id)).to be_empty
    expect(artifact.reload.unreferenced_since).to be_present
  end

  it "rejects a result produced for a report replaced while the processor was running" do
    report
    upload_native(project)
    original = report.manifest.deep_dup
    allow(Artifacts::NativeSymbols::Processor).to receive(:call).and_wrap_original do |method, **arguments|
      result = method.call(**arguments)
      report.destroy!
      project.crash_reports.create!(event_id: event.event_id, manifest: original)
      result
    end
    expect { Errors::Symbolication::Record.call(event: event) }.to raise_error(Artifacts::Unavailable, "Crash report changed during resolution")
    expect(Errors::Symbolication.where(event_id: event.id)).to be_empty
    expect(Artifacts::Reference.where(project_id: project.id)).to be_empty
  end

  it "stores an explicit retryable outage while preserving the raw crash" do
    report
    upload_native(project)
    endpoint = ENV.delete("NATIVE_SYMBOL_PROCESSOR_URL")
    expect { Errors::Symbolication::Record.call(event: event) }.to raise_error(Artifacts::Unavailable)
    expect(read).to include("reason" => "processing_unavailable", "retryable" => true)
    expect(report.reload.manifest).to be_present
  ensure
    ENV["NATIVE_SYMBOL_PROCESSOR_URL"] = endpoint if endpoint
  end

  it "applies the full-frame budget before processor calls without truncating the original report" do
    report.update!(manifest: report.manifest.merge("threads" => [ { "thread_id" => 1, "frames" => [ native_fixture.fetch("frames").first.fetch("raw") ] * 501 } ]))
    expect(Artifacts::NativeSymbols::Processor).not_to receive(:call)
    Errors::Symbolication::Record.call(event: event)
    expect(read).to include("reason" => "native_budget", "frames" => [])
    expect(report.reload.manifest.fetch("threads").first.fetch("frames").size).to eq(501)
  end

  it "reports a source read budget separately from absent or expired crash evidence" do
    report.update!(manifest: report.manifest.merge("diagnostic" => "a" * 5.megabytes))
    expect { read }.to raise_error(Artifacts::Rejected, "native_source_budget")
  end

  it "does not start persistence after the whole native job deadline has elapsed" do
    report
    allow(Process).to receive(:clock_gettime).and_call_original
    ticks = [ 100.0, 131.0 ]
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_wrap_original { |method, clock| ticks.shift || method.call(clock) }
    expect { Errors::Symbolication::Record.call(event: event) }.to raise_error(Artifacts::Unavailable, "Native resolution deadline exceeded")
    expect(Errors::Symbolication.where(event_id: event.id)).to be_empty
  end
end
