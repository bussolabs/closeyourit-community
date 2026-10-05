# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::PruneJob do
  include ActiveJob::TestHelper

  it "dispatches existing tenants and orphaned blob owners separately" do
    project = create(:project)
    orphan_id = SecureRandom.uuid
    blob = Artifacts::Blob.create!(project_id: orphan_id, key: "artifacts/#{SecureRandom.hex(32)}", service_name: "test",
      byte_size: 1, sha256: Digest::SHA256.hexdigest("x"), reserved_until: 1.hour.from_now)
    blob.service.upload(blob.key, StringIO.new("x"))
    clear_enqueued_jobs
    described_class.perform_now
    owners = enqueued_jobs.select { |job| job[:job] == described_class }.map { |job| job[:args].first["project_id"] }
    expect(owners).to include(project.id, orphan_id)
    described_class.perform_now(project_id: orphan_id)
    expect(Artifacts::Blob.exists?(blob.id)).to be(false)
    expect(blob.service.exist?(blob.key)).to be(false)
  ensure
    blob&.service&.delete(blob.key)
  end

  it "resumes after a project cursor without redispatching older owners" do
    projects = [ create(:project), create(:project) ].sort_by(&:id)
    clear_enqueued_jobs
    described_class.perform_now(after_project_id: projects.first.id)
    owners = enqueued_jobs.select { |job| job[:job] == described_class }.map { |job| job[:args].first["project_id"] }
    expect(owners).to include(projects.last.id)
    expect(owners).not_to include(projects.first.id)
  end
end
