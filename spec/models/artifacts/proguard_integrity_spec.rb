# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ProGuard artifact integrity" do
  let(:project) { create(:project) }
  let(:other) { create(:project) }
  let(:blob) { Artifacts::Blob.create!(project_id: project.id, key: "artifacts/#{SecureRandom.hex(32)}", service_name: "test", byte_size: 1, sha256: "a" * 64, reserved_until: 1.hour.from_now) }
  let(:artifact) { Artifacts::ProguardMap.create!(project: project, blob: blob, release: "v1", debug_id: SecureRandom.uuid, identity_sha256: "b" * 64) }
  let(:symbolication) { Errors::Symbolication.create!(project: project, event_id: SecureRandom.uuid, event_created_at: Time.current, result: {}) }

  it "enforces same-project blobs and mutually exclusive typed references in PostgreSQL" do
    blob
    other
    symbolication
    expect do
      ApplicationRecord.transaction(requires_new: true) { Artifacts::ProguardMap.create!(project: other, blob: blob, release: "v1", debug_id: SecureRandom.uuid, identity_sha256: "c" * 64) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
    artifact
    expect do
      ApplicationRecord.transaction(requires_new: true) { Artifacts::Reference.insert_all!([ { project_id: project.id, symbolication_id: symbolication.id } ]) }
    end.to raise_error(ActiveRecord::StatementInvalid)
    expect do
      ApplicationRecord.transaction(requires_new: true) { Artifacts::Reference.create!(project: other, symbolication: symbolication, proguard_map: artifact) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
    Artifacts::Reference.create!(project: project, symbolication: symbolication, proguard_map: artifact)
  end

  it "does not collect live ProGuard blobs but removes them after tenant deletion" do
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
end
