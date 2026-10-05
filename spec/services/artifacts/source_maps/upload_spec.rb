# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::SourceMaps::Upload do
  let(:project) { create(:project) }
  let(:account) { create(:account) }
  let(:map) { { "version" => 3, "sources" => [ "source.ts" ], "sourcesContent" => [ "private source" ], "names" => [], "mappings" => "AAAA" } }
  let(:metadata) { { "release" => "v1", "generated_file" => "https://example.test/app.js" } }

  def upload(value = map)
    described_class.call(project: project, account: account, metadata: metadata, map: value)
  end

  it "stores only the sanitized map and deduplicates without refreshing retention" do
    first = upload.artifact
    expect(Artifacts::SourceMaps::Read.call(artifact: first).to_json).not_to include("private source", "sourcesContent")
    initial = first.unreferenced_since
    travel 2.days do
      repeated = upload
      expect(repeated.duplicate).to be(true)
      expect(repeated.artifact.id).to eq(first.id)
      expect(first.reload.unreferenced_since).to eq(initial)
    end
    expect(project.source_map_artifacts.count).to eq(1)
    expect(Artifacts::Blob.where(project_id: project.id).count).to eq(1)
  end

  it "rejects different mappings for the same immutable build identity" do
    first = upload.artifact
    expect { upload(map.merge("mappings" => "AACA")) }.to raise_error(Artifacts::Conflict)
    expect(project.source_map_artifacts.sole.id).to eq(first.id)
  end

  it "counts active reservations in the project quota" do
    20.times do
      Artifacts::Blob.create!(project_id: project.id, key: "artifacts/#{SecureRandom.hex(32)}", service_name: "test", byte_size: Artifacts::MAX_MAP, sha256: "a" * 64, reserved_until: 1.hour.from_now)
    end
    expect { upload }.to raise_error(Artifacts::Rejected, "project_artifact_quota")
    expect(project.source_map_artifacts.count).to eq(0)
  end
end
