# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Symbolication::Java::Resolve do
  let(:project) { create(:project) }
  let(:event) { create(:error_event, project: project, release: "v1", payload: {}) }

  it "keeps absent, malformed and conflicting build identities unresolved" do
    [ {}, { "debug_meta" => [] }, { "debug_meta" => { "images" => {} } },
      { "debug_meta" => { "images" => [ nil, { "type" => "elf" } ] } } ].each do |payload|
      event.payload = payload
      expect(described_class.call(event: event)).to include("reason" => "missing_build_identity")
    end
    event.payload = { "debug_meta" => { "images" => [ { "type" => "proguard", "uuid" => SecureRandom.uuid }, { "type" => "proguard", "uuid" => SecureRandom.uuid } ] } }
    expect(described_class.call(event: event)).to include("reason" => "identity_mismatch")
    event.payload["debug_meta"]["images"].pop
    expect(described_class.call(event: event)).to include("reason" => "missing_artifact")
    event.release = nil
    expect(described_class.call(event: event)).to include("reason" => "missing_build_identity")
  end

  it "keeps recorded unmapped R8 output separate from ambiguous and removed alternatives" do
    resolver = described_class.new(event: event)
    artifact = Artifacts::ProguardMap.new(id: SecureRandom.uuid)
    response = JSON.parse(Pathname(__dir__).join("../../../../fixtures/artifacts/retrace-processor-response.json").read).fetch("response")
    group = response.fetch("groups").first
    source = { "line" => group.fetch("alternatives").first.fetch("lines").first, "kind" => "exception" }
    expect(resolver.send(:project_group, group, source, artifact)).to include("status" => "unmapped")
    expect(resolver.send(:project_group, group.merge("alternatives" => []), source, artifact)).to include("status" => "removed")
    expect(resolver.send(:project_group, group.merge("alternatives" => [ { "lines" => [] } ]), source, artifact)).to include("status" => "removed")
    expect(resolver.send(:project_group, group.merge("ambiguous" => true), source, artifact)).to include("status" => "ambiguous")
    expect(resolver.send(:project_group, group.merge("alternatives" => group["alternatives"] * 2), source, artifact)).to include("status" => "ambiguous")
    expect(resolver.send(:project_group, group, source.merge("line" => "different input"), artifact)).to include("status" => "mapped")
  end

  it "maps processor rejections to explicit bounded failure reasons" do
    resolver = described_class.new(event: event)
    { "unsupported_stack" => "unsupported_stack", "invalid_stack" => "unsupported_stack", "request_too_large" => "symbolication_budget",
      "retrace_rejected" => "processing_rejected", "invalid_mapping" => "processing_rejected", "other" => "identity_mismatch" }.each do |code, reason|
      expect(resolver.send(:rejection_reason, code)).to eq(reason)
    end
  end
end
