# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::SourceMaps::Decode, "input boundaries" do
  let(:map) { JSON.parse(Rails.root.join("spec/fixtures/artifacts/source_maps/nuxt_4_5_2_index.json").read) }

  def decode(value) = described_class.call(map: value)

  def section(value, line: 0, column: 0)
    { "offset" => { "line" => line, "column" => column }, "map" => value }
  end

  def indexed(*sections) = { "version" => 3, "sections" => sections }

  def function_range(first, last, name: "observedFunction")
    { "source_index" => 0, "start_line" => first, "start_column" => 0,
      "end_line" => last, "end_column" => 0, "name" => name }
  end

  def with_functions(ranges)
    map.merge("x_closeyourit_functions" => { "version" => 1, "ranges" => ranges })
  end

  it "rejects unsupported document shapes and references to absent names" do
    [ nil, [], map.merge("version" => 2) ].each do |value|
      expect { decode(value) }.to raise_error(Artifacts::Rejected, "invalid_source_map")
    end
    expect { decode(map.merge("mappings" => nil)) }.to raise_error(Artifacts::Rejected, "invalid_mappings")
    expect { decode(map.merge("names" => [])) }.to raise_error(Artifacts::Rejected, "name_index")
    [ [], { "version" => 2, "ranges" => [] }, { "version" => 1, "ranges" => nil } ].each do |extension|
      expect { decode(map.merge("x_closeyourit_functions" => extension)) }.to raise_error(Artifacts::Rejected, "invalid_functions")
    end
  end

  it "does not invent mapped positions for empty segments and trailing empty lines" do
    padded = map.merge("mappings" => "," + map.fetch("mappings") + ",;;;")
    expect(decode(padded)).to eq(decode(map))
  end

  it "accepts the maximum nesting depth and rejects one further embedded map" do
    nested = map
    Artifacts::MAX_DEPTH.times { nested = indexed(section(nested)) }
    expect(decode(nested)).to eq(decode(map))
    expect { decode(indexed(section(nested))) }.to raise_error(Artifacts::Rejected, "source_map_depth")
  end

  it "counts empty sections against the total parsing budget" do
    empty = map.merge("mappings" => "", "sources" => [], "names" => [])
    sections = Array.new(Artifacts::MAX_SECTIONS) { |index| section(empty, line: index) }
    expect(decode(indexed(*sections)).fetch("segments")).to be_empty
    expect { decode(indexed(*sections, section(empty, line: sections.size))) }.to raise_error(Artifacts::Rejected, "section_budget")
  end

  it "rejects external, malformed and mixed indexed maps" do
    expect { decode(indexed(section(map).merge("url" => "https://example.test/map"))) }.to raise_error(Artifacts::Rejected, "external_section")
    expect { decode(indexed(section(map)).merge("mappings" => "")) }.to raise_error(Artifacts::Rejected, "invalid_sections")
    expect { decode(map.merge("sections" => {})) }.to raise_error(Artifacts::Rejected, "invalid_sections")
    expect { decode(indexed(section(map).merge("offset" => nil))) }.to raise_error(Artifacts::Rejected, "invalid_section_offset")
    [ nil, -1, 0.5, "0", Artifacts::MAX_POSITION + 1 ].each do |offset|
      expect { decode(indexed(section(map, line: offset))) }.to raise_error(Artifacts::Rejected, "invalid_position")
    end
  end

  it "rejects a later section that starts inside the preceding generated output" do
    end_column = decode(map).fetch("segments").last.fetch(1)
    expect { decode(indexed(section(map), section(map, column: end_column))) }.to raise_error(Artifacts::Rejected, "overlapping_sections")
  end

  it "applies string table budgets across sections rather than separately" do
    %w[sources names].each do |table|
      half = map.merge("mappings" => "", table => Array.new(5_000, map.fetch(table).first))
      expect(decode(indexed(section(half), section(half, line: 1))).fetch(table).size).to eq(10_000)
      excessive = half.merge(table => half.fetch(table) + [ map.fetch(table).first ])
      reason = table == "sources" ? "source_budget" : "name_budget"
      expect { decode(indexed(section(half), section(excessive, line: 1))) }.to raise_error(Artifacts::Rejected, reason)
    end
  end

  it "keeps nullable source slots and rejects malformed string tables" do
    expect(decode(map.merge("sources" => [ nil ])).fetch("sources")).to eq([ nil ])
    [ nil, [ nil ], [ 12 ], [ "bad\0name" ], [ "x" * 4_097 ] ].each do |names|
      expect { decode(map.merge("names" => names)) }.to raise_error(Artifacts::Rejected, "invalid_string_table")
    end
  end

  it "bounds a joined source name as well as its two input parts" do
    relative = map.merge("sourceRoot" => "src", "sources" => [ "index.vue" ])
    expect(decode(relative).fetch("sources")).to eq([ "src/index.vue" ])
    expect(decode(relative.merge("sources" => [ "/index.vue" ])).fetch("sources")).to eq([ "/index.vue" ])
    expect { decode(relative.merge("sourceRoot" => "x" * 4_096)) }.to raise_error(Artifacts::Rejected, "source_name_budget")
    [ 3, "bad\0root", "x" * 4_097 ].each do |root|
      expect { decode(map.merge("sourceRoot" => root)) }.to raise_error(Artifacts::Rejected, "invalid_source_root")
    end
  end

  it "rejects excessive input before discarding source contents and bounds normalized output" do
    expect { decode(map.merge("sourcesContent" => [ " " * Artifacts::MAX_REQUEST ])) }.to raise_error(Artifacts::Rejected, "source_map_too_large")
    large = map.merge("mappings" => "", "names" => [], "sources" => Array.new(10_000, "source/" + "x" * 600))
    expect(large.to_json.bytesize).to be < Artifacts::MAX_REQUEST
    expect { decode(large) }.to raise_error(Artifacts::Rejected, "normalized_map_too_large")
  end

  it "accepts the segment limit and rejects one extra compiler-derived segment" do
    segment = map.fetch("mappings").split(/[;,]/).first
    bounded = map.merge("mappings" => Array.new(Artifacts::MAX_SEGMENTS, segment).join(","))
    expect(decode(bounded).fetch("segments").size).to eq(Artifacts::MAX_SEGMENTS)
    expect { decode(bounded.merge("mappings" => bounded.fetch("mappings") + "," + segment)) }.to raise_error(Artifacts::Rejected, "segment_budget")
  end

  it "accepts adjacent ranges and rejects duplicate, empty and malformed ranges" do
    ranges = [ function_range(0, 1), function_range(1, 2) ]
    expect(decode(with_functions(ranges)).fetch("functions")).to eq(ranges)
    expect { decode(with_functions([ ranges.first, ranges.first ])) }.to raise_error(Artifacts::Rejected, "ambiguous_function_range")
    [ nil, function_range(1, 1), function_range(2, 1) ].each do |range|
      expect { decode(with_functions([ range ])) }.to raise_error(Artifacts::Rejected, "invalid_function_range")
    end
    [ "", 12, "x" * 513 ].each do |name|
      expect { decode(with_functions([ function_range(0, 1, name: name) ])) }.to raise_error(Artifacts::Rejected, "invalid_function_name")
    end
  end

  it "bounds function nesting separately from the number of function ranges" do
    nested = Array.new(64) { |index| function_range(index, 130 - index) }
    expect(decode(with_functions(nested)).fetch("functions").size).to eq(64)
    expect { decode(with_functions(nested + [ function_range(64, 66) ])) }.to raise_error(Artifacts::Rejected, "function_nesting_budget")
    adjacent = Array.new(Artifacts::MAX_FUNCTIONS) { |index| function_range(index, index + 1) }
    expect(decode(with_functions(adjacent)).fetch("functions").size).to eq(Artifacts::MAX_FUNCTIONS)
    expect { decode(with_functions(adjacent + [ function_range(10_000, 10_001) ])) }.to raise_error(Artifacts::Rejected, "function_budget")
  end
end
