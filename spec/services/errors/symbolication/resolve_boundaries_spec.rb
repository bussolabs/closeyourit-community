# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Symbolication::Resolve do
  let(:project) { create(:project) }
  let(:map) { JSON.parse(Rails.root.join("spec/fixtures/artifacts/source_maps/nuxt_4_5_2_index.json").read) }
  let(:position) { Artifacts::SourceMaps::Decode.call(map: map).fetch("segments").find { |row| row.size >= 5 } }
  let(:frame) { { "filename" => map.fetch("file"), "lineno" => position[0] + 1, "colno" => position[1] + 1 } }

  def event(frames:, release: "v1", **payload)
    create(:error_event, project: project, release: release, stacktrace: { "frames" => frames },
      payload: { "platform" => "javascript" }.merge(payload.stringify_keys))
  end

  def upload(**metadata)
    Artifacts::SourceMaps::Upload.call(project: project, account: nil, map: map,
      metadata: { "release" => "v1", "generated_file" => map.fetch("file") }.merge(metadata.stringify_keys)).artifact
  end

  it "preserves malformed frames and explains why they cannot be mapped" do
    frames = [ nil, { "filename" => "https://user:pass@example.test/app.js" }, frame.merge("lineno" => 0), frame.merge("colno" => 1.5) ]
    result = described_class.call(event: event(frames: frames))
    expect(result["frames"].map { |row| row["status"] }).to eq(%w[missing_position unsupported missing_position missing_position])
    expect(result["stacktrace"]["frames"]).to eq(frames)
  end

  it "requires a build identity even when a matching path exists" do
    upload
    expect(described_class.call(event: event(frames: [ frame ], release: nil))["frames"].first["status"]).to eq("missing_build_identity")
  end

  it "ignores unrelated debug images but rejects conflicting matching identities" do
    id = SecureRandom.uuid
    artifact = upload(debug_id: id)
    images = [ nil, { "type" => "elf" }, { "type" => "sourcemap", "code_file" => "other.js", "debug_id" => SecureRandom.uuid },
      { "type" => "sourcemap", "code_file" => map.fetch("file"), "debug_id" => id } ]
    entry = event(frames: [ frame ], debug_meta: { "images" => images })
    expect(described_class.call(event: entry)["frames"].first).to include("status" => "mapped", "artifact_id" => artifact.id)
    entry.stacktrace["frames"][0]["debug_id"] = SecureRandom.uuid
    expect(described_class.call(event: entry)["frames"].first["status"]).to eq("identity_mismatch")
    entry.stacktrace["frames"][0]["debug_id"] = "invalid"
    expect(described_class.call(event: entry)["frames"].first["status"]).to eq("identity_mismatch")
  end

  it "handles missing and malformed exception containers without inventing frames" do
    [ nil, "invalid", {} ].each do |values|
      expect(described_class.call(event: event(frames: [], exception: { "values" => values }))).to include("status" => "unresolved", "exceptions" => [], "frames" => [])
    end
    entry = event(frames: [], exception: { "values" => [ nil, {}, { "stacktrace" => { "frames" => "invalid" } } ] })
    expect(described_class.call(event: entry)["exceptions"]).to eq([ {}, { "stacktrace" => { "frames" => [] } }, { "stacktrace" => { "frames" => [] } } ])
  end

  it "returns a partial result without changing the unmapped frame or original event" do
    upload
    frames = [ frame, frame.merge("filename" => "missing.js") ]
    entry = event(frames: frames)
    original = entry.attributes.deep_dup
    result = described_class.call(event: entry)
    expect(result["status"]).to eq("partial")
    expect(result["frames"].map { |row| row["status"] }).to eq(%w[mapped missing_artifact])
    expect(result["stacktrace"]["frames"].last).to eq(frames.last)
    expect(entry.attributes).to eq(original)
  end

  it "keeps positions without a segment unmapped" do
    upload
    result = described_class.call(event: event(frames: [ frame.merge("lineno" => 100_000) ]))
    expect(result["frames"].first["status"]).to eq("unmapped")
  end

  it "bounds frame count across primary and exception stacks together" do
    entry = event(frames: [ frame ] * 500, exception: { "values" => [ { "stacktrace" => { "frames" => [ frame ] } } ] })
    expect(described_class.call(event: entry)).to include("reason" => "symbolication_budget", "frames" => [])
    expect(described_class.call(event: event(frames: [ frame ] * 500)) ["frames"].size).to eq(500)
  end

  it "bounds the complete output, including retained frame metadata" do
    entry = event(frames: [ frame.merge("context_line" => "x" * 1.megabyte) ])
    expect(described_class.call(event: entry)).to include("reason" => "symbolication_budget", "frames" => [])
  end
end
