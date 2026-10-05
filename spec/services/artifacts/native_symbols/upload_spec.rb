# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::NativeSymbols::Upload do
  let(:project) { create(:project) }

  it "rejects a different valid object with the same build identity without reserving another blob" do
    original = upload_native(project)
    expect do
      described_class.call(project: project, account: nil, metadata: native_fixture.fetch("symbols"), object_base64: Base64.strict_encode64(native_bytes + "\0"))
    end.to raise_error(Artifacts::Conflict, "artifact_identity_conflict")
    expect(project.native_symbol_artifacts.count).to eq(1)
    expect(Artifacts::Blob.where(project_id: project.id).count).to eq(1)
    expect(Artifacts::NativeSymbols::Read.call(artifact: original)).to eq(native_bytes)
  end

  it "does not reserve storage when the processor cannot validate the actual object" do
    bytes = native_bytes
    metadata = native_fixture.fetch("symbols")
    endpoint = ENV.delete("NATIVE_SYMBOL_PROCESSOR_URL")
    expect { described_class.call(project: project, account: nil, metadata: metadata, object_base64: Base64.strict_encode64(bytes)) }.to raise_error(Artifacts::Unavailable)
    expect(Artifacts::Blob.where(project_id: project.id)).to be_empty
  ensure
    ENV["NATIVE_SYMBOL_PROCESSOR_URL"] = endpoint if endpoint
  end
end
