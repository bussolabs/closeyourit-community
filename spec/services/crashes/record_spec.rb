# frozen_string_literal: true

require "rails_helper"

RSpec.describe Crashes::Record do
  let(:project) { create(:project) }
  let(:event) { { "event_id" => "a" * 32, "release" => "v1" } }
  def item(bytes = "hello", filename = "notes.txt")
    { header: { "filename" => filename }, bytes: bytes }
  end

  it "persists only scrubbed objects and deduplicates without refreshing retention" do
    first = described_class.call(project: project, event: event, items: [ item('{"password":1234,"nested":{"token":{"value":"private"}}}') ])
    expect(first.accepted).to eq(1)
    attachment = first.report.attachments.sole
    expect(attachment.blob.service.download(attachment.blob.key)).not_to include("1234", "private")
    arrived = first.report.created_at
    travel 1.day do
      replay = described_class.call(project: project, event: event, items: [ item('{"password":1234,"nested":{"token":{"value":"private"}}}') ])
      expect(replay.duplicates).to eq(1)
      expect(replay.report.reload.created_at).to eq(arrived)
      expect(Crashes::Blob.where(project_id: project.id).count).to eq(1)
    end
  end

  it "rejects conflicting identities and metadata while admitting independent attachments" do
    described_class.call(project: project, event: event, items: [ item ])
    second = described_class.call(project: project, event: event, items: [ item("changed"), item("other", "other.txt"), item("\xff".b, "opaque.bin") ])
    expect(second.to_h).to include(accepted: 1, rejected: 2)
    expect(second.diagnostics).to include("attachment_identity_conflict" => 1, "unsupported_binary" => 1)
    conflict = described_class.call(project: project, event: event.merge("release" => "v2"), items: [ item("new", "third.txt") ])
    expect(conflict.diagnostics).to eq("event_metadata_conflict" => 1)
    expect(project.crash_reports.sole.release).to eq("v1")
  end

  it "counts pending storage against project quota and does not create empty reports" do
    10.times { Crashes::Blob.create!(project_id: project.id, key: SecureRandom.hex, service_name: "test", byte_size: Crashes::MAX_FILE, sha256: "a" * 64, reserved_until: 1.hour.from_now) }
    result = described_class.call(project: project, event: event, items: [ item ])
    expect(result.diagnostics).to eq("project_storage_quota" => 1)
    expect(project.crash_reports.count).to eq(0)
  end

  it "limits attachments across repeated envelopes and keeps separate project identities" do
    first = described_class.call(project: project, event: event, items: 11.times.map { |i| item("value", "#{i}.txt") })
    expect(first.to_h).to include(accepted: 10, rejected: 1)
    extra = described_class.call(project: project, event: event, items: [ item("value", "last.txt") ])
    expect(extra.diagnostics).to eq("too_many_attachments" => 1)
    other = create(:project)
    expect(described_class.call(project: other, event: event, items: [ item ]).accepted).to eq(1)
  end

  it "removes mismatched attachments when the authoritative event arrives later" do
    first = described_class.call(project: project, event: event, items: [ item ])
    Errors::Ingest::Record.call(project: project, payload: event.merge("release" => "v2", "message" => "Late crash"))
    expect(Crashes::Report.exists?(first.report.id)).to be(false)
    expect(project.error_events.sole.release).to eq("v2")
  end

  it "rejects a changed distribution and mismatched explicit build identity" do
    described_class.call(project: project, event: event.merge("dist" => "1"), items: [ item ])
    conflict = described_class.call(project: project, event: event.merge("dist" => "2"), items: [ item("different", "build.txt") ])
    expect(conflict.diagnostics).to eq("event_metadata_conflict" => 1)
    expect(Crashes::Identity.compatible_build?({ "debug_meta" => { "images" => [ { "debug_id" => "abc", "code_id" => "123" } ] } }, { "modules" => [ { "debug_id" => "abc", "code_id" => "456" }, { "debug_id" => "def", "code_id" => "123" } ] })).to be(false)
  end

  it "treats empty release, environment and distribution as missing values" do
    payload = event.merge("release" => "", "environment" => "", "dist" => "", "message" => "Crash")
    report = described_class.call(project: project, event: payload, items: [ item ]).report
    Errors::Ingest::Record.call(project: project, payload: payload)
    expect(report.reload.attributes.slice("release", "environment", "dist")).to eq("release" => nil, "environment" => nil, "dist" => nil)
  end
end
