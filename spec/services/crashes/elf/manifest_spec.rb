# frozen_string_literal: true

require "rails_helper"

RSpec.describe Crashes::Elf::Manifest do
  let(:payload) { JSON.parse(Rails.root.join("spec/fixtures/artifacts/native-elf-event.json").read) }

  it "preserves actual crash instructions and full ELF identities" do
    original = payload.deep_dup
    result = described_class.call(payload: payload)
    expect(result["system_info"]).to eq("os" => "Linux", "cpu_arch" => "arm64")
    expect(result["modules"].map { |image| image["code_id"] }).to eq(payload.dig("debug_meta", "images").map { |image| image["code_id"] })
    expected = payload.dig("exception", "values").sole.dig("stacktrace", "frames").reverse.map { |frame| frame["instruction_addr"] }
    expect(result["threads"].sole["frames"].map { |frame| frame["instruction"] }).to eq(expected)
    expect(result.dig("crash_info", "crashing_thread")).to eq(0)
    expect(payload).to eq(original)
  end

  it "accepts the Android profile only when explicitly declared" do
    payload["contexts"]["os"]["name"] = "Android"
    expect(described_class.call(payload: payload).dig("system_info", "os")).to eq("Android")
    payload["contexts"].delete("os")
    expect { described_class.call(payload: payload) }.to raise_error(Crashes::Rejected)
  end

  it "rejects malformed shapes, conflicting architectures and unsafe image ranges" do
    variants = [ payload.merge("contexts" => []), payload.merge("exception" => "invalid"), payload.merge("debug_meta" => []) ]
    image = payload.dig("debug_meta", "images").first
    [ image.merge("type" => "macho"), image.merge("arch" => "x86_64"), image.merge("image_size" => -1), image.merge("image_addr" => "0xffffffffffffffff") ].each do |invalid|
      variants << payload.deep_merge("debug_meta" => { "images" => [ invalid ] })
    end
    variants.each { |candidate| expect { described_class.call(payload: candidate) }.to raise_error(Crashes::Rejected) }
  end

  it "preserves missing build identities without inventing them" do
    payload.dig("debug_meta", "images").each { |image| image.delete("code_id"); image.delete("debug_id") }
    described_class.call(payload: payload)["modules"].each do |image|
      expect(image).not_to have_key("code_id")
      expect(image).not_to have_key("debug_id")
    end
  end

  it "does not pick one crashing stack when several exceptions are unhandled" do
    exception = payload.dig("exception", "values").sole
    payload["exception"]["values"] << exception.deep_dup
    result = described_class.call(payload: payload)
    expect(result["threads"].size).to eq(2)
    expect(result["crash_info"]).not_to have_key("crashing_thread")
  end

  it "rejects excess frames rather than truncating a crash" do
    exception = payload.dig("exception", "values").sole
    exception["stacktrace"]["frames"] *= 43
    expect { described_class.call(payload: payload) }.to raise_error(Crashes::Rejected, "native_budget")
  end

  it "enforces collection budgets and requires nonempty stacks and image tables" do
    exception = payload.dig("exception", "values").sole
    image = payload.dig("debug_meta", "images").first
    [ nil, [], [ nil ], [ exception ] * 11 ].each do |values|
      expect { described_class.call(payload: payload.deep_merge("exception" => { "values" => values })) }.to raise_error(Crashes::Rejected)
    end
    [ nil, [], [ nil ], [ image ] * 129 ].each do |images|
      expect { described_class.call(payload: payload.deep_merge("debug_meta" => { "images" => images })) }.to raise_error(Crashes::Rejected)
    end
    [ nil, [], [ nil ], [ { "instruction_addr" => "invalid" } ] ].each do |frames|
      candidate = payload.deep_dup
      candidate["exception"]["values"].sole["stacktrace"]["frames"] = frames
      expect { described_class.call(payload: candidate) }.to raise_error(Crashes::Rejected)
    end
  end

  it "enforces the shared resolver total frame budget at exactly 500" do
    exception = payload.dig("exception", "values").sole
    frame = exception.dig("stacktrace", "frames").first
    exception["stacktrace"]["frames"] = [ frame ] * 250
    payload["exception"]["values"] << exception.deep_dup
    expect(described_class.call(payload: payload)["threads"].sum { |thread| thread["frames"].size }).to eq(500)
    payload["exception"]["values"].last["stacktrace"]["frames"] << frame
    expect { described_class.call(payload: payload) }.to raise_error(Crashes::Rejected, "native_budget")
  end

  it "rejects invalid IDs while accepting absent module architecture" do
    image = payload.dig("debug_meta", "images").first
    image.delete("arch")
    expect(described_class.call(payload: payload)["modules"].size).to eq(5)
    [ "private-id", "00000000", 123 ].each do |value|
      image["code_id"] = value
      expect { described_class.call(payload: payload) }.to raise_error(Crashes::Rejected)
    end
    image.delete("code_id")
    image["debug_id"] = "invalid"
    expect { described_class.call(payload: payload) }.to raise_error(Crashes::Rejected)
  end

  it "rejects ambiguous or unsupported profile labels without inferring a platform" do
    [ nil, "arm64", [], %w[arm64 x86_64], [ "mips" ] ].each do |architectures|
      candidate = payload.deep_dup
      candidate["contexts"]["device"]["archs"] = architectures
      expect { described_class.call(payload: candidate) }.to raise_error(Crashes::Rejected)
    end
    [ nil, [], payload.merge("platform" => "cocoa") ].each do |candidate|
      expect { described_class.call(payload: candidate) }.to raise_error(Crashes::Rejected)
    end
  end
end
