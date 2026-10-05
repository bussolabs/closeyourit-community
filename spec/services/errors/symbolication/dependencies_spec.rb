# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Symbolication::Dependencies do
  it "unions declared and rendered dependencies and preserves legacy source map entries" do
    id = SecureRandom.uuid
    expect(described_class.call(result: { "dependencies" => [], "frames" => [ { "artifact_id" => id } ] })).to eq([ { "kind" => "source_map", "id" => id } ])
    expect(described_class.call(result: { "frames" => [], "groups" => [ { "artifact_id" => id, "artifact_kind" => "proguard_map" } ] })).to eq([ { "kind" => "proguard_map", "id" => id } ])
  end

  it "fails closed on unknown explicit kinds even with an empty declared dependency set" do
    expect { described_class.call(result: { "dependencies" => [], "frames" => [ { "artifact_kind" => "future_kind", "artifact_id" => SecureRandom.uuid } ] }) }.to raise_error(Artifacts::Rejected)
    expect { described_class.call(result: { "dependencies" => [], "frames" => [ { "artifact_kind" => nil } ] }) }.to raise_error(Artifacts::Rejected)
  end

  it "counts distinct native artifacts rather than repeated frame references at the frame limit" do
    entry = { "kind" => "native_symbol", "id" => SecureRandom.uuid }
    frames = Array.new(500) { { "artifact_kind" => entry["kind"], "artifact_id" => entry["id"] } }
    expect(described_class.call(result: { "dependencies" => [ entry ], "frames" => frames })).to eq([ entry ])
  end
end
