# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Crash storage integrity" do
  let(:project) { create(:project) }
  let(:other) { create(:project) }

  it "rejects cross-project blob and report associations in PostgreSQL" do
    report = Crashes::Report.create!(project: project, event_id: "a" * 32)
    blob = Crashes::Blob.create!(project_id: other.id, key: SecureRandom.hex, service_name: "test", byte_size: 1, sha256: "a" * 64, reserved_until: Time.current)
    expect do
      Crashes::Attachment.transaction(requires_new: true) do
        Crashes::Attachment.create!(project: project, report: report, blob: blob, filename: "file.txt", kind: "text")
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
    expect do
      Crashes::Attachment.transaction(requires_new: true) do
        Crashes::Attachment.create!(project: other, report: report, blob: blob, filename: "file.txt", kind: "text")
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "enforces storage size and retention boundaries at the database boundary" do
    expect do
      Crashes::Blob.transaction(requires_new: true) do
        Crashes::Blob.insert_all!([ { project_id: project.id, key: SecureRandom.hex, service_name: "test", byte_size: Crashes::MAX_FILE + 1, sha256: "a" * 64, reserved_until: Time.current } ])
      end
    end.to raise_error(ActiveRecord::StatementInvalid)
    [ 1, 365 ].each { |days| expect(project.update(crashes_retention_days: days)).to be(true) }
    [ 0, 366 ].each { |days| expect(project.update(crashes_retention_days: days)).to be(false) }
  end
end
