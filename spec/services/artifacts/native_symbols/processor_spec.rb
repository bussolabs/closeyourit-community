# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::NativeSymbols::Processor do
  it "validates strict response types, identity, positions and inline availability against real processor output" do
    expected = Artifacts::NativeSymbols::Identity.call(metadata: native_fixture.fetch("symbols"))
    processor = described_class.new(bytes: native_bytes, expected: expected, addresses: [ "0x41e8" ])
    response = processor.call
    mutations = [
      ->(value) { value["schema_version"] = 1.0 },
      ->(value) { value["selected"] = 0.0 },
      ->(value) { value["objects"][0]["code_id"] = "c" * 40 },
      ->(value) { value["frames"][0]["index"] = 0.0 },
      ->(value) { value["frames"][0]["address"] = "0x41e9" },
      ->(value) { value["frames"][0]["status"] = "unresolved" },
      ->(value) { value["frames"][0]["locations"][0]["line"] = 1.5 },
      ->(value) { value["frames"][0]["locations"][0]["file"] = "a\0b" },
      ->(value) { value["frames"][0]["locations"] *= 17 }
    ]
    mutations.each do |mutate|
      invalid = response.deep_dup
      mutate.call(invalid)
      expect { processor.send(:validate_response, invalid) }.to raise_error(Artifacts::Unavailable)
    end
    expect(response.fetch("frames").first.fetch("locations").size).to eq(2)
  end

  it "rejects malformed objects with an explicit processor rejection" do
    native_fixture
    expect { described_class.call(bytes: "not an executable", expected: {}, addresses: []) }.to raise_error(Artifacts::Rejected, "native_processing_rejected")
  end
end
