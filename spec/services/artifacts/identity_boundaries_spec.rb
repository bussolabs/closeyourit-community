# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Artifact identity boundaries" do
  it "rejects malformed native profiles and nonstring debug identifiers" do
    [ nil, [], {}, { "format" => "elf", "architecture" => "arm32" },
      { "format" => "macho", "architecture" => "arm64", "debug_id" => 1 } ].each do |metadata|
      expect { Artifacts::NativeSymbols::Identity.call(metadata: metadata) }.to raise_error(Artifacts::Rejected)
    end
  end

  it "rejects unsafe release identities in both Java and source-map metadata" do
    id = SecureRandom.uuid
    metadata = { "release" => "Bearer test-only-value", "debug_id" => id, "generated_file" => "app.js" }
    expect { Artifacts::SourceMaps::Identity.call(metadata: metadata, map: {}) }.to raise_error(Artifacts::Rejected, "unsafe_build_identity")
    expect { Artifacts::ProguardMaps::Identity.call(metadata: metadata) }.to raise_error(Artifacts::Rejected, "unsafe_build_identity")
    expect { Artifacts::ProguardMaps::Identity.call(metadata: metadata.merge("release" => "")) }.to raise_error(Artifacts::Rejected, "missing_release")
    expect(Artifacts::ProguardMaps::Identity.call(metadata: metadata.merge("release" => "v1", "dist" => "2"))).to include(dist: "2")
  end

  it "rejects URL credentials, scrubbed paths and invalid UUID hyphen placement" do
    expect { Artifacts::SourceMaps::Identity.generated_file("https://test-user@example.test/app.js") }.to raise_error(Artifacts::Rejected, "generated_file_userinfo")
    expect { Artifacts::SourceMaps::Identity.generated_file("/build/Bearer%20value/app.js") }.not_to raise_error
    expect { Artifacts::SourceMaps::Identity.generated_file("/build/test@example.test/app.js") }.to raise_error(Artifacts::Rejected, "unsafe_generated_file")
    id = SecureRandom.hex(16)
    expect { Artifacts::SourceMaps::Identity.debug_id(id[0, 4] + "----" + id[4..]) }.to raise_error(Artifacts::Rejected, "invalid_debug_id")
    [ nil, 1, "a\0b", "\xff".b.force_encoding("UTF-8"), "x" * 37 ].each do |value|
      expect { Artifacts::SourceMaps::Identity.text(value, 36) }.to raise_error(Artifacts::Rejected, "invalid_identity")
    end
  end
end
