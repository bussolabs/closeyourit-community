# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Artifact reservation boundaries" do
  [ [ Artifacts::NativeSymbols::Upload, :native_symbol_artifacts ], [ Artifacts::ProguardMaps::Upload, :proguard_map_artifacts ] ].each do |uploader, association|
    context uploader.name do
      let(:project) { create(:project) }
      let(:identity) do
        if association == :native_symbol_artifacts
          proof = JSON.parse(Pathname(__dir__).join("../../fixtures/artifacts/native-processor-response.json").read)
          Artifacts::NativeSymbols::Identity.call(metadata: proof.fetch("response").fetch("objects").first)
        else
          Artifacts::ProguardMaps::Identity.call(metadata: { "release" => "v1", "debug_id" => SecureRandom.uuid })
        end
      end
      let(:identity_digest) { Digest::SHA256.hexdigest(identity.to_json) }
      let(:digest) { Digest::SHA256.hexdigest(Rails.root.join("spec/fixtures/artifacts/r8-9.4.28-mapping.txt").binread) }
      let(:service) do
        input = association == :native_symbol_artifacts ? { object_base64: "" } : { mapping: "" }
        uploader.new(project: project, account: nil, metadata: {}, **input).tap do |instance|
          # Exercise admission after parsing, independently of processor availability.
          instance.instance_variable_set(:@identity, identity)
          instance.instance_variable_set(:@identity_digest, identity_digest)
          instance.instance_variable_set(:@digest, digest)
        end
      end

      it "reserves once, reuses matching content and rejects conflicting content" do
        blob, existing = service.send(:reserve, 16)
        expect(existing).to be_nil
        expect(blob).to have_attributes(project_id: project.id, byte_size: 16, sha256: digest)
        artifact = project.public_send(association).create!(**identity, blob: blob, identity_sha256: identity_digest)
        expect(service.send(:reserve, 16)).to eq([ nil, artifact ])
        service.instance_variable_set(:@digest, "0" * 64)
        expect { service.send(:reserve, 16) }.to raise_error(Artifacts::Conflict, "artifact_identity_conflict")
        expect(Artifacts::Blob.where(project_id: project.id).count).to eq(1)
      end

      it "counts uncommitted reservations against the project quota" do
        (Artifacts::MAX_PROJECT_BYTES / Artifacts::MAX_MAP).times do
          Artifacts::Blob.create!(project_id: project.id, key: "artifacts/#{SecureRandom.hex(32)}", service_name: "test",
          byte_size: Artifacts::MAX_MAP, sha256: digest, reserved_until: 1.hour.from_now)
        end
        expect { service.send(:reserve, 1) }.to raise_error(Artifacts::Rejected, "project_artifact_quota")
        expect(project.public_send(association)).to be_empty
      end
    end
  end

  it "rejects noncanonical base64 before native validation or reservation" do
    proof = JSON.parse(Pathname(__dir__).join("../../fixtures/artifacts/native-processor-response.json").read)
    metadata = proof.fetch("response").fetch("objects").first
    project = create(:project)
    [ nil, "!", "eB==", "x" * (Artifacts::NativeSymbols::Processor::MAX_REQUEST + 1) ].each do |input|
      expect { Artifacts::NativeSymbols::Upload.call(project: project, account: nil, metadata: metadata, object_base64: input) }.to raise_error(Artifacts::Rejected, "invalid_native_object")
    end
    expect(Artifacts::Blob.where(project_id: project.id)).to be_empty
  end
end
