# frozen_string_literal: true

require "rails_helper"

RSpec.describe Crashes::PruneJob do
  let(:project) { create(:project) }

  def store
    Crashes::Record.call(project: project, event: { "event_id" => "a" * 32 }, items: [ { header: { "filename" => "note.txt" }, bytes: "hello" } ]).report
  end

  it "deletes expired report rows and private objects" do
    report = store
    blob = report.attachments.sole.blob
    report.update_columns(created_at: 31.days.ago)
    blob.update_columns(reserved_until: 1.hour.ago)
    described_class.perform_now
    expect(Crashes::Report.exists?(report.id)).to be(false)
    expect(Crashes::Blob.exists?(blob.id)).to be(false)
    expect(blob.service.exist?(blob.key)).to be(false)
  end

  it "retains opaque lifecycle rows until objects are removed after a project cascade" do
    report = store
    blob = report.attachments.sole.blob
    project.destroy!
    expect(Crashes::Attachment.where(report_id: report.id)).to be_empty
    expect(Crashes::Blob.exists?(blob.id)).to be(true)
    described_class.perform_now
    expect(blob.service.exist?(blob.key)).to be(false)
    expect(Crashes::Blob.exists?(blob.id)).to be(false)
  end

  it "does not delete active reservations and cleans abandoned reservations" do
    blob = Crashes::Blob.create!(project_id: project.id, key: SecureRandom.hex, service_name: "test", byte_size: 0, sha256: "a" * 64, reserved_until: 1.hour.from_now)
    described_class.perform_now
    expect(Crashes::Blob.exists?(blob.id)).to be(true)
    travel 2.hours do
      described_class.perform_now
      expect(Crashes::Blob.exists?(blob.id)).to be(false)
    end
  end
end
