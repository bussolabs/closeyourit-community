# frozen_string_literal: true

require "rails_helper"

RSpec.describe Measurements::Series::Query, "typed filter boundaries" do
  let(:project) { create(:project) }

  def query(filters)
    described_class.call(scope: project.measurement_series, filters: filters).to_a
  end

  it "rejects malformed serialized filters and invalid scalar identities" do
    [ "{", "[]", { "id" => "not-a-uuid" }, { "identity_digest" => "A" * 64 },
      { "name" => "x\0y" }, { "name" => [] }, { "name" => "x" * 257 } ].each do |filters|
      expect { query(filters) }.to raise_error(described_class::Invalid)
    end
    expect(query({ "id" => SecureRandom.uuid }.to_json)).to eq([])
    expect(query("identity_digest" => "a" * 64)).to eq([])
  end

  it "requires exactly one typed scalar and a bounded nonempty attribute key" do
    [ nil, {}, { "key" => "", "value" => { "stringValue" => "v" } },
      { "key" => "x", "value" => {} }, { "key" => "x", "value" => { "boolValue" => true, "stringValue" => "v" } },
      { "key" => "x\0y", "value" => { "stringValue" => "v" } } ].each do |item|
      expect { query("point_attributes" => [ item ]) }.to raise_error(described_class::Invalid)
    end
    expect { query("resource_attributes" => {}) }.to raise_error(described_class::Invalid)
  end

  it "validates finite doubles, boolean values and exact signed integer limits" do
    invalid = [ { "doubleValue" => "1.0" }, { "boolValue" => "true" }, { "intValue" => (2**63).to_s },
      { "intValue" => "01" }, { "stringValue" => "x\0y" }, { "stringValue" => "x" * 4097 } ]
    invalid.each do |value|
      expect { query("point_attributes" => [ { "key" => "reading", "value" => value } ]) }.to raise_error(described_class::Invalid)
    end
    [ { "boolValue" => false }, { "doubleValue" => 1.5 }, { "intValue" => (-(2**63)).to_s }, { "intValue" => (2**63 - 1).to_s } ].each do |value|
      expect(query("resource_attributes" => [ { "key" => "reading", "value" => value } ])).to eq([])
    end
  end
end
