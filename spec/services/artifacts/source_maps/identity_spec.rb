# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::SourceMaps::Identity do
  it "canonicalizes URLs exactly as stored event paths without basename matching" do
    input = { "release" => " v1 ", "dist" => "", "generated_file" => "https://example.test/assets/app.js?v=private#fragment", "debug_id" => "A" * 32 }
    value = described_class.call(metadata: input, map: {})
    expect(value).to include(release: " v1 ", dist: nil, generated_file: "https://example.test/assets/app.js", debug_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    scrubbed = Errors::Ingest::Scrub.call(payload: { "abs_path" => input.fetch("generated_file") })
    expect(value.fetch(:generated_file)).to eq(scrubbed.fetch("abs_path"))
  end

  it "rejects userinfo, blank releases and contradictory debug identifiers" do
    base = { "release" => "v1", "generated_file" => "https://example.test/app.js" }
    expect { described_class.call(metadata: base.merge("release" => " "), map: {}) }.to raise_error(Artifacts::Rejected)
    expect { described_class.call(metadata: base.merge("generated_file" => "https://user:secret@example.test/app.js"), map: {}) }.to raise_error(Artifacts::Rejected)
    expect { described_class.call(metadata: base.merge("debug_id" => "a" * 32), map: { "debug_id" => "b" * 32 }) }.to raise_error(Artifacts::Rejected)
  end
end
