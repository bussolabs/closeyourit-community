# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cocoa crash ingestion" do
  let(:project) { create(:project) }
  let(:payload) do
    { "event_id" => SecureRandom.hex(16), "platform" => "cocoa", "release" => "consumer@1", "environment" => "test",
      "exception" => { "values" => [ { "type" => "NativeCrash", "value" => "Crash", "mechanism" => { "handled" => false } } ] },
      "contexts" => { "os" => { "name" => "macOS" }, "device" => { "arch" => "arm64" } },
      "debug_meta" => { "images" => [ { "type" => "macho", "debug_id" => "e633bc80-53b3-4b50-8acf-ef994b52c903", "image_addr" => "0x100000000", "image_size" => 4096, "code_file" => "Consumer" } ] },
      "threads" => { "values" => [ { "id" => 42, "crashed" => true, "stacktrace" => { "frames" => [ { "instruction_addr" => "0x100000010" } ] } } ] } }
  end

  it "creates an event-scoped manifest and schedules native resolution without an attachment" do
    expect { Errors::Ingest::Record.call(project: project, payload: payload) }.to have_enqueued_job(Errors::SymbolicateJob)
    report = project.crash_reports.sole
    expect(report.event_id).to eq(payload["event_id"])
    expect(report.manifest.dig("system_info", "cpu_arch")).to eq("arm64")
    expect(report.attachments).to be_empty
    result = Errors::Symbolication::Resolve.call(event: project.error_events.sole)
    expect(result).to include("kind" => "native", "status" => "unresolved")
    expect(result["frames"].sole["status"]).to eq("missing_artifact")
  end

  it "keeps repeated delivery idempotent and never records an event in another project" do
    event = Errors::Ingest::Record.call(project: project, payload: payload).value
    report = project.crash_reports.sole
    expect { Errors::Ingest::Record.call(project: project, payload: payload) }.not_to change { report.reload.updated_at }
    other = create(:project)
    expect { Crashes::Cocoa::Record.call(project: other, event: event) }.not_to change { other.crash_reports.count }
  end

  it "retains malformed error events without creating a misleading native report" do
    payload["debug_meta"]["images"].sole["image_size"] = -1
    result = Errors::Ingest::Record.call(project: project, payload: payload)
    expect(result).to be_ok
    expect(project.crash_reports).to be_empty
    expect(project.error_events.count).to eq(1)
  end
end
