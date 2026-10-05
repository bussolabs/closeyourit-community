# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::PruneJob do
  let(:project) { create(:project) }
  let(:artifact) do
    Artifacts::SourceMaps::Upload.call(project: project, account: create(:account),
      metadata: { "release" => "v1", "generated_file" => "app.js" },
      map: { "version" => 3, "sources" => [ "source.ts" ], "names" => [], "mappings" => "AAAA" }).artifact
  end

  it "keeps referenced maps and starts the grace period after the retained event disappears" do
    blob = artifact.blob
    event = Errors::Ingest::Record.call(project: project, payload: { "event_id" => "b" * 32, "message" => "failure" }).value
    result = Errors::Symbolication.create!(project_id: project.id, event_id: event.id, event_created_at: event.created_at, result: {})
    Artifacts::Reference.create!(project_id: project.id, source_map_id: artifact.id, symbolication_id: result.id)
    artifact.update!(unreferenced_since: nil)
    described_class.perform_now(project_id: project.id)
    expect(artifact.reload.unreferenced_since).to be_nil
    event.destroy!
    described_class.perform_now(project_id: project.id)
    grace_start = artifact.reload.unreferenced_since
    expect(grace_start).to be_within(1.second).of(Time.current)
    expect(Errors::Symbolication.exists?(result.id)).to be(false)
    travel 29.days do
      described_class.perform_now(project_id: project.id)
      expect(artifact.reload.unreferenced_since).to eq(grace_start)
    end
    travel 31.days do
      described_class.perform_now(project_id: project.id)
      expect(Artifacts::SourceMap.exists?(artifact.id)).to be(false)
      expect(Artifacts::Blob.exists?(blob.id)).to be(false)
      expect(blob.service.exist?(blob.key)).to be(false)
    end
  end

  it "limits each project pass and schedules continuation for a full batch" do
    now = Time.current
    rows = 101.times.map do
      { project_id: project.id, event_id: SecureRandom.uuid, event_created_at: now,
        result: {}, created_at: now, updated_at: now }
    end
    Errors::Symbolication.insert_all!(rows)
    expect { described_class.perform_now(project_id: project.id) }
      .to have_enqueued_job(described_class).with(project_id: project.id)
    expect(Errors::Symbolication.where(project_id: project.id).count).to eq(1)
    described_class.perform_now(project_id: project.id)
    expect(Errors::Symbolication.where(project_id: project.id).count).to eq(0)
  end
  it "keeps another project's unreferenced artifacts outside the requested collection pass" do
    other = create(:project)
    foreign = Artifacts::SourceMaps::Upload.call(project: other, account: create(:account),
      metadata: { "release" => "v1", "generated_file" => "app.js" },
      map: { "version" => 3, "sources" => [ "source.ts" ], "names" => [], "mappings" => "AAAA" }).artifact
    foreign.update!(unreferenced_since: 90.days.ago)
    original_timestamp = foreign.unreferenced_since
    artifact
    described_class.perform_now(project_id: project.id)
    expect(foreign.reload.unreferenced_since).to eq(original_timestamp)
    expect(Artifacts::Blob.exists?(foreign.blob_id)).to be(true)
  end
end
