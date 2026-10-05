# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ingest::OtlpValues do
  let(:decoder) { Object.new.extend(described_class) }

  it "rejects nonobjects, multiple oneof values and invalid typed values" do
    expect { decoder.send(:object, []) }.to raise_error(described_class::Malformed)
    [ { "boolValue" => "true" }, { "bytesValue" => 1 }, { "bytesValue" => "!" },
      { "intValue" => "1", "stringValue" => "1" }, { "doubleValue" => "not-a-number" },
      { "doubleValue" => Float::INFINITY } ].each do |value|
      expect { decoder.send(:any_value, value, depth: 0) }.to raise_error(described_class::Rejected)
    end
  end
end
