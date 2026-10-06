# frozen_string_literal: true

require "rails_helper"

RSpec.describe Crashes::Cocoa::Manifest do
  let(:payload) do
    { "platform" => "cocoa", "contexts" => { "os" => { "name" => "macOS" }, "device" => { "arch" => "arm64" } },
      "debug_meta" => { "images" => [ { "type" => "macho", "debug_id" => "e633bc80-53b3-4b50-8acf-ef994b52c903", "image_addr" => "0x100000000", "image_size" => 4096, "code_file" => "/private/app/Consumer" } ] },
      "threads" => { "values" => [ { "id" => 42, "crashed" => true, "stacktrace" => { "frames" => [ { "instruction_addr" => "0x100000020" }, { "instruction_addr" => "0x100000010" } ] } } ] } }
  end

  it "preserves raw instructions and build identity without copying private context" do
    payload["contexts"]["device"]["name"] = "private-canary"
    result = described_class.call(payload: payload)
    expect(result["system_info"]).to eq("os" => "macOS", "cpu_arch" => "arm64")
    expect(result["modules"].sole).to include("base_addr" => "0x100000000", "end_addr" => "0x100001000", "filename" => "Consumer", "debug_id" => "e633bc80-53b3-4b50-8acf-ef994b52c903")
    expect(result["threads"].sole).to include("thread_id" => 42)
    expect(result["crash_info"]).to eq("crashing_thread" => 0)
    expect(result["threads"].sole.fetch("frames").map { |frame| frame["instruction"] }).to eq(%w[0x100000010 0x100000020])
    expect(result.to_json).not_to include("private-canary", "/private/")
  end

  it "refuses missing architecture and unknown platforms instead of guessing" do
    payload["contexts"]["device"]["arch"] = "unknown"
    expect { described_class.call(payload: payload) }.to raise_error(Crashes::Rejected)
    payload["contexts"]["device"]["arch"] = "arm64"
    payload["contexts"]["os"]["name"] = "Linux"
    expect { described_class.call(payload: payload) }.to raise_error(Crashes::Rejected)
  end

  it "rejects missing image sizes, overflow and invalid build identities" do
    image = payload["debug_meta"]["images"].sole
    [ image.except("image_size"), image.merge("image_size" => -1), image.merge("image_addr" => "0xffffffffffffffff"), image.merge("debug_id" => "invalid") ].each do |invalid|
      candidate = payload.deep_merge("debug_meta" => { "images" => [ invalid ] })
      expect { described_class.call(payload: candidate) }.to raise_error(Crashes::Rejected)
    end
  end

  it "keeps missing frame addresses explicit and rejects the total frame budget" do
    frames = payload["threads"]["values"].sole["stacktrace"]["frames"]
    frames << { "function" => "missing instruction" }
    result = described_class.call(payload: payload)
    expect(result["threads"].sole["frames"].first).not_to have_key("instruction")
    payload["threads"]["values"] = [ payload["threads"]["values"].sole.deep_dup ] * 128
    payload["threads"]["values"].each { |thread| thread["stacktrace"]["frames"] = frames * 2 }
    expect { described_class.call(payload: payload) }.to raise_error(Crashes::Rejected, "native_budget")
  end
end
