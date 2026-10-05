# frozen_string_literal: true

require "rails_helper"

RSpec.describe Crashes::Manifest, "untrusted report boundaries" do
  def report(**values)
    { "schema_version" => 1, "modules" => [], "threads" => [] }.merge(values.stringify_keys)
  end

  it "retains bounded system and crash metadata while omitting null fields" do
    result = described_class.call(report(system_info: { "os" => "Linux", "cpu_arch" => nil },
      crash_info: { "type" => "SIGSEGV", "crashing_thread" => 0, "address" => "0x12" }))
    expect(result["system_info"]).to eq("os" => "Linux")
    expect(result["crash_info"]).to eq("type" => "SIGSEGV", "crashing_thread" => 0, "address" => "0x12")
    expect(described_class.call(report(system_info: nil))["system_info"]).to eq({})
  end

  it "rejects wrong scalar types and invalid unsigned thread identifiers" do
    [ 1, [], "Linux" ].each do |value|
      expect { described_class.call(report(system_info: value)) }.to raise_error(Crashes::Rejected, "invalid_report")
    end
    expect { described_class.call(report(system_info: { "os" => 42 })) }.to raise_error(Crashes::Rejected, "invalid_report")
    [ -1, 2**32, 1.5 ].each do |id|
      expect { described_class.call(report(threads: [ { "thread_id" => id } ])) }.to raise_error(Crashes::Rejected, "invalid_report")
    end
  end

  it "rejects strings that cannot safely cross the diagnostic boundary" do
    [ "bad\0name", "x" * 4097, "\xff".dup.force_encoding(Encoding::UTF_8) ].each do |value|
      expect { described_class.call(report(system_info: { "os" => value })) }.to raise_error(Crashes::Rejected, "invalid_report")
    end
    [ "https://example.test", "g123", "0x12\n" ].each do |value|
      expect { described_class.call(report(crash_info: { "address" => value })) }.to raise_error(Crashes::Rejected, "invalid_report")
    end
  end

  it "bounds projected size even when each module remains individually valid" do
    modules = Array.new(300) { { "filename" => "x" * 4096 } }
    expect { described_class.call(report(modules: modules)) }.to raise_error(Crashes::Rejected, "report_too_large")
  end
end
