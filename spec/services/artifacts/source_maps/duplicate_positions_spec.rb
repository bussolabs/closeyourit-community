# frozen_string_literal: true

require "spec_helper"
require "json"
require "active_support/all"
require_relative "../../../../app/services/application_service"
require_relative "../../../../app/models/artifacts"
require_relative "../../../../app/services/ingest/pii_scrubbing"
require_relative "../../../../app/services/errors/ingest/scrub"
require_relative "../../../../app/services/artifacts/source_maps/vlq"
require_relative "../../../../app/services/artifacts/source_maps/decode"
require_relative "../../../../app/services/artifacts/source_maps/lookup"

RSpec.describe Artifacts::SourceMaps::Decode, "duplicate generated positions" do
  let(:map) { { "version" => 3, "sources" => [ "one.js", "two.js" ], "names" => [ "first", "second" ], "mappings" => "AAAA" } }

  it "decodes the actual Nuxt 4 map prepared by the packed CLI without source contents" do
    input = JSON.parse(File.read(File.expand_path("../../../fixtures/artifacts/source_maps/nuxt_4_5_2_index.json", __dir__)))
    expect(input).not_to have_key("sourcesContent")
    decoded = described_class.call(map: input)
    expect(decoded.fetch("segments").size).to eq(154)
    { 520 => [ 22, 5 ], 633 => [ 23, 71 ] }.each do |column, position|
      result = Artifacts::SourceMaps::Lookup.call(map: decoded, line: 0, column: column)
      expect(result.fetch("original").values_at("filename", "lineno", "colno", "function")).to eq([ "../../../app/pages/index.vue", *position, nil ])
      expect(result.fetch("mapped_name")).to eq("_cache")
    end
    expect(decoded.to_json).not_to include("sourcesContent")
  end

  it "preserves the sole known name regardless of duplicate order" do
    [ "AAAAA,AAAA", "AAAA,AAAAA", "AAAAA,AAAAA" ].each do |mappings|
      expect(described_class.call(map: map.merge("mappings" => mappings)).fetch("segments")).to eq([ [ 0, 0, 0, 0, 0, 0 ] ])
    end
  end

  it "conservatively rejects different name indices even when their text is equal" do
    expect { described_class.call(map: map.merge("names" => [ "same", "same" ], "mappings" => "AAAAC,AAAAD")) }.to raise_error(Artifacts::Rejected, "ambiguous_generated_position")
  end

  it "rejects conflicting known names even when privacy filtering makes them equal" do
    [ [ "first", "second" ], [ "Bearer synthetic-first", "Bearer synthetic-second" ] ].each do |names|
      expect { described_class.call(map: map.merge("names" => names, "mappings" => "AAAAA,AAAAC")) }.to raise_error(Artifacts::Rejected, "ambiguous_generated_position")
    end
  end

  it "rejects conflicting source indices, original lines and original columns" do
    [ "AAAA,ACAA", "AAAA,AACA", "AAAA,AAAC" ].each do |mappings|
      expect { described_class.call(map: map.merge("mappings" => mappings)) }.to raise_error(Artifacts::Rejected, "ambiguous_generated_position")
    end
  end

  it "coalesces identical unnamed mappings and repeated unmapped markers" do
    expect(described_class.call(map: map.merge("mappings" => "AAAA,AAAA")).fetch("segments")).to eq([ [ 0, 0, 0, 0, 0 ] ])
    expect(described_class.call(map: map.merge("mappings" => "A,A")).fetch("segments")).to eq([ [ 0, 0 ] ])
  end

  it "rejects mixed mapped and unmapped segments in either order" do
    [ "A,AAAA", "AAAA,A" ].each do |mappings|
      expect { described_class.call(map: map.merge("mappings" => mappings)) }.to raise_error(Artifacts::Rejected, "ambiguous_generated_position")
    end
  end

  it "enforces the input segment budget before coalescing duplicates" do
    expect { described_class.call(map: map.merge("mappings" => Array.new(Artifacts::MAX_SEGMENTS + 1, "A").join(","))) }.to raise_error(Artifacts::Rejected, "segment_budget")
  end
end
