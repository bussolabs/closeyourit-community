# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::SourceMaps::Decode do
  let(:map) { { "version" => 3, "sources" => [ "src/example.ts" ], "sourcesContent" => [ "const password = 'private';" ], "names" => [ "greet" ], "mappings" => "AAAAA,K,CAAC" } }

  it "decodes mapped and explicitly unmapped segments without persisting source contents" do
    value = described_class.call(map: map)
    expect(value.fetch("segments")).to eq([ [ 0, 0, 0, 0, 0, 0 ], [ 0, 5 ], [ 0, 6, 0, 0, 1 ] ])
    expect(value.to_json).not_to include("sourcesContent", "private", "password")
  end

  it "rejects malformed VLQ, invalid source indices and overflowing deltas" do
    [ "!", "g", "ACAA", "ggggggggggggA", "AA", "D" ].each do |mappings|
      expect { described_class.call(map: map.merge("mappings" => mappings)) }.to raise_error(Artifacts::Rejected)
    end
  end

  it "applies embedded offsets only to the first generated line and remaps local source indices" do
    value = described_class.call(map: { "version" => 3, "sections" => [ { "offset" => { "line" => 2, "column" => 7 }, "map" => map.merge("mappings" => "AAAA;AACA") } ] })
    expect(value.fetch("segments")).to eq([ [ 2, 7, 0, 0, 0 ], [ 3, 0, 0, 1, 0 ] ])
  end

  it "rejects external sections and overlapping embedded maps" do
    expect { described_class.call(map: { "version" => 3, "sections" => [ { "offset" => { "line" => 0, "column" => 0 }, "url" => "https://example.test/map" } ] }) }.to raise_error(Artifacts::Rejected)
    section = { "offset" => { "line" => 0, "column" => 0 }, "map" => map }
    expect { described_class.call(map: { "version" => 3, "sections" => [ section, section ] }) }.to raise_error(Artifacts::Rejected)
  end

  it "preserves bounded function ranges separately from mapped symbols" do
    range = { "source_index" => 0, "start_line" => 0, "start_column" => 0, "end_line" => 3, "end_column" => 0, "name" => "originalFunction" }
    value = described_class.call(map: map.merge("x_closeyourit_functions" => { "version" => 1, "ranges" => [ range ] }))
    expect(value.fetch("functions")).to eq([ range ])
    expect(value.fetch("names")).to eq([ "greet" ])
    expect { described_class.call(map: map.merge("x_closeyourit_functions" => { "version" => 1, "ranges" => [ range.merge("source_index" => 1) ] })) }.to raise_error(Artifacts::Rejected)
  end

  it "scrubs names and source URLs while preserving numeric mapping coordinates" do
    value = described_class.call(map: map.merge("sources" => [ "https://name:secret@example.test/source.ts?token=hidden" ], "names" => [ "Bearer synthetic-value" ]))
    expect(value.fetch("sources")).to eq([ "https://example.test/source.ts" ])
    expect(value.to_json).not_to include("secret", "hidden", "synthetic-value")
  end
  it "uses anonymous inner ranges as masks instead of attributing the outer function" do
    outer = { "source_index" => 0, "start_line" => 0, "start_column" => 0, "end_line" => 10, "end_column" => 0, "name" => "outer" }
    inner = outer.merge("start_line" => 1, "end_line" => 3, "name" => nil)
    decoded = described_class.call(map: map.merge("mappings" => "AACA", "x_closeyourit_functions" => { "version" => 1, "ranges" => [ outer, inner ] }))
    expect(Artifacts::SourceMaps::Lookup.call(map: decoded, line: 0, column: 0).fetch("original").fetch("function")).to be_nil
    decoded["segments"] = [ [ 0, 0, 0, 3, 0 ] ]
    expect(Artifacts::SourceMaps::Lookup.call(map: decoded, line: 0, column: 0).fetch("original").fetch("function")).to eq("outer")
  end

  it "rejects crossing ranges and counts the ECMA negative-zero VLQ as minimum int32" do
    expect(Artifacts::SourceMaps::Vlq.decode("B")).to eq([ -(2**31) ])
    expect { described_class.call(map: map.merge("mappings" => "B")) }.to raise_error(Artifacts::Rejected)
    range = { "source_index" => 0, "start_line" => 0, "start_column" => 0, "end_line" => 3, "end_column" => 0, "name" => "outer" }
    expect { described_class.call(map: map.merge("x_closeyourit_functions" => { "version" => 1, "ranges" => [ range, range.merge("start_line" => 1, "end_line" => 4) ] })) }.to raise_error(Artifacts::Rejected, "crossing_function_ranges")
  end

  it "uses the ECMA global GLB lookup across empty and delayed indexed sections" do
    [ "", "KAAA" ].each do |mappings|
      sections = [
        { "offset" => { "line" => 0, "column" => 0 }, "map" => map.merge("mappings" => "AAAA") },
        { "offset" => { "line" => 0, "column" => 10 }, "map" => map.merge("mappings" => mappings) }
      ]
      decoded = described_class.call(map: { "version" => 3, "sections" => sections })
      expect(Artifacts::SourceMaps::Lookup.call(map: decoded, line: 0, column: 9)).not_to be_nil
      expect(Artifacts::SourceMaps::Lookup.call(map: decoded, line: 0, column: 10)).not_to be_nil
      expect(Artifacts::SourceMaps::Lookup.call(map: decoded, line: 0, column: 12)).not_to be_nil
      expect(Artifacts::SourceMaps::Lookup.call(map: decoded, line: 0, column: 15)).not_to be_nil if mappings.present?
    end
  end
end
