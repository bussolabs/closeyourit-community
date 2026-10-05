# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::ProguardBackfillJob do
  include ActiveJob::TestHelper

  around { |example| Time.use_zone("Europe/Rome") { example.run } }

  let(:project) { create(:project) }
  let(:group) { create(:error_group, project: project) }
  let(:artifact) do
    mapping = Rails.root.join("spec/fixtures/artifacts/r8-9.4.28-mapping.txt").binread
    identity = Artifacts::ProguardMaps::Identity.call(metadata: { "release" => "v1", "debug_id" => SecureRandom.uuid })
    blob = Artifacts::Blob.create!(project_id: project.id, key: "artifacts/#{SecureRandom.hex(32)}",
      service_name: "test", byte_size: mapping.bytesize, sha256: Digest::SHA256.hexdigest(mapping), reserved_until: 1.hour.from_now)
    # Backfill selects stored metadata; processor admission is covered separately.
    project.proguard_map_artifacts.create!(**identity, blob: blob, identity_sha256: Digest::SHA256.hexdigest(identity.to_json))
  end

  def event(**attributes)
    create(:error_event, project: project, group: group, release: "v1", payload: { "platform" => "java" }, **attributes)
  end

  def scheduled_events
    enqueued_jobs.select { |job| job[:job] == Errors::SymbolicateJob }.map { |job| job[:args].first.fetch("event_id") }
  end

  it "ignores missing projects, missing artifacts and another tenant's artifact" do
    own_id = artifact.id
    clear_enqueued_jobs
    described_class.perform_now(project_id: SecureRandom.uuid, proguard_map_id: own_id)
    described_class.perform_now(project_id: project.id, proguard_map_id: SecureRandom.uuid)
    described_class.perform_now(project_id: create(:project).id, proguard_map_id: own_id)
    expect(enqueued_jobs).to be_empty
  end

  it "does not enqueue work for an empty release" do
    artifact
    clear_enqueued_jobs
    described_class.perform_now(project_id: project.id, proguard_map_id: artifact.id)
    expect(enqueued_jobs).to be_empty
  end

  it "selects only retained Java events in the artifact's project and release" do
    matching = event
    event(release: "v2")
    event(payload: { "platform" => "javascript" })
    event(created_at: (Errors::Retention.for(project) + 1).days.ago)
    create(:error_event, release: "v1", payload: { "platform" => "java" })
    artifact
    clear_enqueued_jobs
    described_class.perform_now(project_id: project.id, proguard_map_id: artifact.id)
    expect(scheduled_events).to eq([ matching.id ])
  end

  it "continues a full batch without duplicating events at the same timestamp" do
    time = Time.current.change(usec: 123456)
    ids = Array.new(described_class::BATCH_SIZE + 1) { event(created_at: time).id }.sort
    artifact
    clear_enqueued_jobs
    described_class.perform_now(project_id: project.id, proguard_map_id: artifact.id)
    expect(scheduled_events).to eq(ids.first(described_class::BATCH_SIZE))
    continuation = enqueued_jobs.find { |job| job[:job] == described_class }
    expect(continuation).to be_present
    args = continuation[:args].first
    expect(args.fetch("after_id")).to eq(ids[-2])
    expect(Time.iso8601(args.fetch("after_time"))).to eq(time)

    clear_enqueued_jobs
    described_class.perform_now(project_id: project.id, proguard_map_id: artifact.id,
      after_time: args.fetch("after_time"), after_id: args.fetch("after_id"))
    expect(scheduled_events).to eq([ ids.last ])
    expect(enqueued_jobs.none? { |job| job[:job] == described_class }).to be(true)
  end
end
