# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::NativeSymbols::Identity do
  it "preserves full ELF build identifiers and canonicalizes UUID age without truncation" do
    value = described_class.call(metadata: { "format" => "elf", "architecture" => "x86_64", "debug_id" => "A" * 32 + "1234abcd", "code_id" => "AB" * 20 })
    expect(value).to include(debug_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa-1234abcd", code_id: "ab" * 20)
    expect(described_class.debug_id("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa-0")).to eq("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
  end

  it "rejects zero identifiers, overlong ages, missing ELF build IDs and PDB code IDs" do
    base = { "format" => "elf", "architecture" => "arm64", "debug_id" => "a" * 32, "code_id" => "12ab" }
    [ base.merge("debug_id" => "0" * 32), base.merge("debug_id" => "a" * 41), base.except("code_id"), base.merge("format" => "pdb") ].each do |metadata|
      expect { described_class.call(metadata: metadata) }.to raise_error(Artifacts::Rejected)
    end
  end

  it "preserves full code IDs through the shared CLI limit without truncation" do
    metadata = { "format" => "elf", "architecture" => "arm64", "debug_id" => "a" * 32, "code_id" => "b" * 128 }
    expect(described_class.call(metadata: metadata).fetch(:code_id)).to eq("b" * 128)
    expect { described_class.call(metadata: metadata.merge("code_id" => "b" * 129)) }.to raise_error(Artifacts::Rejected, "invalid_code_id")
  end
end
