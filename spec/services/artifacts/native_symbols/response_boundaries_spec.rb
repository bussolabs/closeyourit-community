# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::NativeSymbols::Processor do
  let(:response) { JSON.parse(Pathname(__dir__).join("../../../fixtures/artifacts/native-processor-response.json").read).fetch("response") }
  let(:processor) { described_class.new(bytes: "invalid", expected: response.fetch("objects").first.slice("debug_id", "architecture", "format", "code_id"), addresses: [ "0x41e8" ]) }

  it "validates the recorded real Linux arm64 response including both inline locations" do
    expect(processor.send(:validate_response, response)).to eq(response)
    expect(response.fetch("frames").first.fetch("locations").size).to eq(2)
  end

  it "rejects invalid envelopes, selection and frame counts" do
    [ nil, [], {}, response.merge("schema_version" => 1.0), response.merge("schema_version" => 2),
      response.merge("objects" => nil), response.merge("objects" => []), response.merge("objects" => response["objects"] * 17),
      response.merge("selected" => 0.0), response.merge("selected" => -1), response.merge("selected" => 1),
      response.merge("frames" => nil), response.merge("frames" => []) ].each do |value|
      expect { processor.send(:validate_response, value) }.to raise_error(Artifacts::Unavailable)
    end
  end

  it "rejects object shape, flags, strings, addresses and mismatched identities" do
    object = response.fetch("objects").first
    [ nil, {}, object.merge("usable" => "true"), object.merge("usable" => false), object.merge("debug_id" => "different"),
      object.merge("format" => nil), object.merge("code_id" => 12), object.merge("code_id" => "x" * 4097),
      object.merge("debug_id" => "a\0b"), object.merge("architecture" => "\xff".dup.force_encoding("UTF-8")),
      object.merge("preferred_load_address" => nil), object.merge("preferred_load_address" => "0X0"),
      object.merge("preferred_load_address" => "0x10000000000000000") ].each do |value|
      expect { processor.send(:validate_response, response.merge("objects" => [ value ])) }.to raise_error(Artifacts::Unavailable)
    end
  end

  it "rejects frame order, shapes, oversized inline chains and inconsistent resolution" do
    frame = response.fetch("frames").first
    [ nil, {}, frame.merge("index" => 0.0), frame.merge("index" => 1), frame.merge("address" => "0x41e9"),
      frame.merge("locations" => nil), frame.merge("locations" => frame["locations"] * 17),
      frame.merge("status" => "unexpected"), frame.merge("status" => "unresolved"), frame.merge("locations" => []) ].each do |value|
      expect { processor.send(:validate_response, response.merge("frames" => [ value ])) }.to raise_error(Artifacts::Unavailable)
    end
  end

  it "rejects invalid location data without accepting numeric coercion" do
    location = response.fetch("frames").first.fetch("locations").first
    [ nil, {}, location.merge("line" => 1.5), location.merge("line" => -1), location.merge("line" => 2**32),
      location.merge("file" => 5), location.merge("symbol" => "a\0b"), location.merge("function" => "x" * 4097),
      location.merge("function_address" => "not-hex") ].each do |value|
      expect { processor.send(:validate_location!, value) }.to raise_error(Artifacts::Unavailable)
    end
    expect { processor.send(:validate_location!, location.merge("file" => nil, "symbol" => nil, "function" => nil, "line" => nil)) }.not_to raise_error
    expect { processor.send(:validate_object!, response["objects"].first.merge("code_id" => nil)) }.not_to raise_error
  end

  it "rejects invalid binary inputs and address ranges before transport" do
    [ nil, "", "x" * (described_class::MAX_BINARY + 1) ].each do |bytes|
      expect { described_class.new(bytes: bytes, expected: {}, addresses: []).send(:validate_input!) }.to raise_error(Artifacts::Rejected, "invalid_native_object")
    end
    [ nil, [ "0x0" ] * 501, [ 0 ], [ "0X0" ], [ "0xffffffff" ], [ "0x100000000" ] ].each do |addresses|
      expect { described_class.new(bytes: "x", expected: {}, addresses: addresses).send(:validate_input!) }.to raise_error(Artifacts::Rejected, "invalid_native_addresses")
    end
    expect { described_class.new(bytes: "x", expected: {}, addresses: [ "0xfffffffe" ] * 500).send(:validate_input!) }.not_to raise_error
  end
end
