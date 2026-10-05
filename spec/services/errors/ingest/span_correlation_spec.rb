# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Ingest::Normalize, "explicit span correlation" do
  it "preserves only valid span identifiers and safely ignores malformed optional contexts" do
    [ nil, "invalid", [], { "trace" => [] }, { "trace" => "invalid" }, { "trace" => { "span_id" => "0" * 16 } } ].each do |contexts|
      result = described_class.call(payload: { "message" => "valid error", "contexts" => contexts })
      expect(result.span_id).to be_nil
    end
    result = described_class.call(payload: { "message" => "valid error", "contexts" => { "trace" => { "span_id" => "B" * 16 } } })
    expect(result.span_id).to eq("b" * 16)
  end
end
