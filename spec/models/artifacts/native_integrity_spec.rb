# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Native artifact integrity" do
  let(:project) { create(:project) }
  let(:other) { create(:project) }
  let(:blob) { Artifacts::Blob.create!(project_id: project.id, key: "artifacts/#{SecureRandom.hex(32)}", service_name: "test", byte_size: 1, sha256: "a" * 64, reserved_until: 1.hour.from_now) }
  let(:artifact) { Artifacts::NativeSymbol.create!(project: project, blob: blob, format: "elf", architecture: "arm64", debug_id: SecureRandom.uuid, code_id: "b" * 40, identity_sha256: "c" * 64) }
  let(:report) { project.crash_reports.create!(event_id: SecureRandom.hex(16)) }
  let(:symbolication) { Errors::Symbolication.create!(project: project, event_id: SecureRandom.uuid, event_created_at: Time.current, result: {}, crash_report: report) }

  it "enforces tenant consistency and cascades report-derived data without deleting the artifact" do
    [ blob, other, report, symbolication ]
    expect do
      ApplicationRecord.transaction(requires_new: true) { Artifacts::NativeSymbol.create!(project: other, blob: blob, format: "elf", architecture: "arm64", debug_id: SecureRandom.uuid, identity_sha256: "d" * 64) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
    expect do
      ApplicationRecord.transaction(requires_new: true) { Errors::Symbolication.create!(project: other, event_id: SecureRandom.uuid, event_created_at: Time.current, result: {}, crash_report: report) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
    expect do
      ApplicationRecord.transaction(requires_new: true) { Artifacts::Reference.create!(project: other, symbolication: symbolication, native_symbol: artifact) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
    artifact
    Artifacts::Reference.create!(project: project, symbolication: symbolication, native_symbol: artifact)
    report.destroy!
    expect(Errors::Symbolication.exists?(symbolication.id)).to be(false)
    expect(Artifacts::Reference.where(native_symbol_id: artifact.id)).to be_empty
    expect(artifact.reload).to be_present
  end

  it "enforces exactly one artifact kind and preserves live native objects through collection" do
    artifact
    symbolication
    expect do
      ApplicationRecord.transaction(requires_new: true) { Artifacts::Reference.insert_all!([ { project_id: project.id, symbolication_id: symbolication.id } ]) }
    end.to raise_error(ActiveRecord::StatementInvalid)
    artifact.update!(unreferenced_since: Time.current)
    blob.update!(reserved_until: 1.minute.ago)
    blob.service.upload(blob.key, StringIO.new("x"))
    Artifacts::PruneJob.perform_now(project_id: project.id)
    expect(blob.service.exist?(blob.key)).to be(true)
    project.destroy!
    Artifacts::PruneJob.perform_now(project_id: project.id)
    expect(Artifacts::Blob.exists?(blob.id)).to be(false)
    expect(blob.service.exist?(blob.key)).to be(false)
  end

  it "admits native object sizes through twenty MiB and rejects negative or oversized lifecycle rows" do
    blob.update!(byte_size: 20.megabytes)
    expect(blob.reload.byte_size).to eq(20.megabytes)
    [ -1, 20.megabytes + 1 ].each do |size|
      expect do
        ApplicationRecord.transaction(requires_new: true) { blob.update!(byte_size: size) }
      end.to raise_error(ActiveRecord::StatementInvalid)
    end
  end
end
