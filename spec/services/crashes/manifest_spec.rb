# frozen_string_literal: true

require "rails_helper"

RSpec.describe Crashes::Manifest do
  it "preserves protocol identities and discards memory, registers and annotations" do
    input = { "schema_version" => 1, "registers" => { "secret" => "private" },
      "modules" => [ { "debug_id" => "abc123", "filename" => "/Users/person/private/app", "annotations" => "private" } ],
      "threads" => [ { "thread_id" => 7, "registers" => "private", "frames" => [ { "instruction" => "0x1234", "trust" => "context", "memory" => "private" } ] } ] }
    value = described_class.call(input)
    expect(value.dig("modules", 0, "debug_id")).to eq("abc123")
    expect(value.dig("modules", 0, "filename")).to eq("app")
    expect(value.dig("threads", 0, "frames", 0, "instruction")).to eq("0x1234")
    expect(value.to_json).not_to include("private", "registers", "annotations", "memory")
  end

  it "rejects wrong shapes and over-budget reports" do
    expect { described_class.call({ "schema_version" => 2 }) }.to raise_error(Crashes::Rejected)
    expect { described_class.call({ "schema_version" => 1, "threads" => Array.new(129) { {} } }) }.to raise_error(Crashes::Rejected)
    expect { described_class.call({ "schema_version" => 1, "modules" => "invalid" }) }.to raise_error(Crashes::Rejected)
  end
end
