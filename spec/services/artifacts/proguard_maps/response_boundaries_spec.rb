# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::ProguardMaps::Processor do
  let(:response) { JSON.parse(Pathname(__dir__).join("../../../fixtures/artifacts/retrace-processor-response.json").read).fetch("response") }
  let(:processor) { described_class.new(mapping: "invalid", stacktrace: Array.new(response.fetch("groups").size, "")) }

  it "validates a recorded response from the actual R8 processor" do
    expect(processor.send(:validate_response!, response)).to eq(response.fetch("groups"))
  end

  it "rejects malformed envelopes, versions, group order and ambiguity" do
    [ nil, {}, response.merge("schema_version" => 1.0), response.merge("schema_version" => 2), response.merge("groups" => nil), response.merge("groups" => []) ].each do |value|
      expect { processor.send(:validate_response!, value) }.to raise_error(Artifacts::Unavailable)
    end
    group = response.fetch("groups").first
    [ nil, {}, group.merge("index" => 0.0), group.merge("index" => 1), group.merge("ambiguous" => nil),
      group.merge("alternatives" => nil), group.merge("alternatives" => group["alternatives"] * 21),
      group.merge("ambiguous" => !group["ambiguous"]) ].each do |value|
      expect { processor.send(:validate_group!, value, 0) }.to raise_error(Artifacts::Unavailable)
    end
  end

  it "rejects invalid alternative lines and enforces the total expansion budget" do
    [ nil, {}, { "lines" => nil }, { "lines" => [ 1 ] }, { "lines" => [ "x" * 16385 ] },
      { "lines" => [ "\xff".dup.force_encoding("UTF-8") ] }, { "lines" => [ "a\nb" ] }, { "lines" => [ "a\0b" ] } ].each do |value|
      expect { processor.send(:validate_alternative!, value) }.to raise_error(Artifacts::Unavailable)
    end
    expanded = response.deep_dup
    expanded["groups"].first["alternatives"] = [ { "lines" => [ "java.lang.IllegalStateException" ] * 2001 } ]
    expect { processor.send(:validate_response!, expanded) }.to raise_error(Artifacts::Unavailable)
    expect(processor.send(:validate_alternative!, { "lines" => [ "x" * 16384 ] })).to eq(1)
  end

  it "validates encoding, line breaks and stack limits before transport" do
    [ nil, "", "\xff".b, "a\0b", "x" * (Artifacts::MAX_MAP + 1) ].each do |mapping|
      expect { described_class.new(mapping: mapping, stacktrace: []).send(:validate_input!) }.to raise_error(Artifacts::Rejected, "invalid_mapping")
    end
    mapping = Rails.root.join("spec/fixtures/artifacts/r8-9.4.28-mapping.txt").read
    [ nil, [ "" ] * 501, [ nil ], [ "\xff".dup.force_encoding("UTF-8") ], [ "x" * 4097 ], [ "a\rb" ] ].each do |stack|
      expect { described_class.new(mapping: mapping, stacktrace: stack).send(:validate_input!) }.to raise_error(Artifacts::Rejected, "invalid_stack")
    end
    expect { described_class.new(mapping: mapping, stacktrace: [ "x" * 4096 ] * 500).send(:validate_input!) }.not_to raise_error
  end
end
