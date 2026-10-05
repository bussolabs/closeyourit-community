# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Symbolication::Native::Stack do
  let(:identity) { { "debug_id" => "a" * 32 + "0", "code_id" => "b" * 40, "filename" => "app" } }
  let(:manifest) do
    { "system_info" => { "os" => "Linux", "cpu_arch" => "amd64" },
      "modules" => [ identity.merge("base_addr" => "0x1000", "end_addr" => "0x2000") ],
      "threads" => [ { "thread_id" => 9, "frames" => [ { "instruction" => "0x1010", "module_offset" => "0x10", "trust" => "context" }, { "instruction" => "0x1020", "trust" => "frame_pointer" } ] } ] }
  end

  it "translates already adjusted walker addresses once and preserves every thread position and trust" do
    frames = described_class.call(manifest: manifest)
    expect(frames.map { |frame| frame["module_offset"] }).to eq(%w[0x10 0x20])
    expect(frames.map { |frame| frame.values_at("thread_index", "frame_index", "trust") }).to eq([ [ 0, 0, "context" ], [ 0, 1, "frame_pointer" ] ])
    expect(frames.first.fetch("identity")).to include(format: "elf", architecture: "x86_64", code_id: "b" * 40)
  end

  it "matches address ranges instead of identical basenames" do
    manifest["modules"] << identity.merge("base_addr" => "0x3000", "end_addr" => "0x4000", "code_id" => "c" * 40)
    manifest["threads"][0]["frames"][0].merge!("instruction" => "0x3010")
    expect(described_class.call(manifest: manifest).first).to include("module_index" => 1, "identity" => include(code_id: "c" * 40))
  end

  it "rejects overlapping modules, inconsistent offsets and overflow without guessing" do
    manifest["modules"] << identity.merge("base_addr" => "0x1800", "end_addr" => "0x3000")
    manifest["threads"][0]["frames"] << { "instruction" => "0x1900" }
    manifest["threads"][0]["frames"] << { "instruction" => "0x4000" }
    expect(described_class.call(manifest: manifest).map { |frame| frame["status"] }).to eq([ nil, nil, "ambiguous_module", "missing_module" ])
    manifest["modules"].pop
    manifest["threads"][0]["frames"][0]["module_offset"] = "0xf"
    expect(described_class.call(manifest: manifest).first["status"]).to eq("invalid_address")
    manifest["modules"][0]["end_addr"] = "0xffffffffffffffff"
    manifest["threads"][0]["frames"][0]["instruction"] = "0x100000fff"
    expect(described_class.call(manifest: manifest).first["status"]).to eq("invalid_address")
  end

  it "keeps unknown architectures and missing full ELF IDs unresolved" do
    manifest["system_info"]["cpu_arch"] = "unknown"
    expect(described_class.call(manifest: manifest).first["status"]).to eq("unsupported_profile")
    manifest["system_info"]["cpu_arch"] = "arm64"
    manifest["modules"][0].delete("code_id")
    expect(described_class.call(manifest: manifest).first["status"]).to eq("missing_build_identity")
  end

  it "supports an empty report and rejects the complete report above the frame budget" do
    expect(described_class.call(manifest: manifest.merge("threads" => []))).to eq([])
    manifest["threads"] = [ { "frames" => [ manifest["threads"][0]["frames"][0] ] * 501 } ]
    expect { described_class.call(manifest: manifest) }.to raise_error(Artifacts::Rejected, "native_budget")
  end
end
