# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ELF crash ingestion" do
  let(:project) { create(:project) }
  let(:payload) { JSON.parse(Rails.root.join("spec/fixtures/artifacts/native-elf-event.json").read) }

  it "persists the real crash without an attachment and exposes its six frames" do
    expect { Errors::Ingest::Record.call(project: project, payload: payload) }.to have_enqueued_job(Errors::SymbolicateJob)
    report = project.crash_reports.sole
    expect(report.event_id).to eq(payload["event_id"])
    expect(report.release).to eq(payload["release"])
    expect(report.environment).to eq(payload["environment"])
    expect(report.attachments).to be_empty
    result = Errors::Symbolication::Resolve.call(event: project.error_events.sole)
    expect(result).to include("kind" => "native", "status" => "unresolved")
    expect(result["frames"].size).to eq(6)
    expect(result["frames"].map { |frame| frame["status"] }.uniq).to eq([ "missing_artifact" ])
  end

  it "preserves original metadata on replay and isolates equal event IDs between projects" do
    event = Errors::Ingest::Record.call(project: project, payload: payload).value
    report = project.crash_reports.sole
    expect { Errors::Ingest::Record.call(project: project, payload: payload.merge("release" => "new@2")) }.not_to change { report.reload.updated_at }
    expect(report.reload.release).to eq(payload["release"])
    other = create(:project)
    expect { Crashes::Elf::Record.call(project: other, event: event) }.not_to change { other.crash_reports.count }
    Errors::Ingest::Record.call(project: other, payload: payload)
    expect(other.crash_reports.sole.id).not_to eq(report.id)
    expect(project.error_events.count).to eq(1)
  end

  it "retains malformed events without fabricating a native report" do
    payload["debug_meta"]["images"].first["image_size"] = -1
    expect(Errors::Ingest::Record.call(project: project, payload: payload)).to be_ok
    expect(project.error_events.count).to eq(1)
    expect(project.crash_reports).to be_empty
  end

  it "recognizes the explicitly declared Android profile without claiming device execution" do
    payload["contexts"]["os"]["name"] = "Android"
    event = Errors::Ingest::Record.call(project: project, payload: payload).value
    expect(Errors::Symbolication::Resolve.call(event: event)["frames"].map { |frame| frame["status"] }.uniq).to eq([ "missing_artifact" ])
  end

  it "does not replace existing crash evidence or resurrect expired events" do
    event = Errors::Ingest::Record.call(project: project, payload: payload).value
    report = project.crash_reports.sole
    manifest = report.manifest.deep_dup
    expect { Crashes::Elf::Record.call(project: project, event: event) }.not_to change { report.reload.updated_at }
    expect(report.reload.manifest).to eq(manifest)
    report.destroy!
    travel_to (Errors::Retention.for(project).days + 1.second).from_now do
      expect(Crashes::Elf::Record.call(project: project, event: event)).to be_nil
      expect(project.crash_reports).to be_empty
    end
    expect(Crashes::Elf::Record.call(project: project, event: nil)).to be_nil
  end
end
