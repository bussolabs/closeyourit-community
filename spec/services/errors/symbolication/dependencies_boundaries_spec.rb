# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Symbolication::Dependencies do
  it "rejects invalid dependency shapes, kinds and identifiers" do
    [ nil, {}, [ {} ], [ { "kind" => "other", "id" => SecureRandom.uuid } ],
      [ { "kind" => "source_map", "id" => 1 } ], [ { "kind" => "source_map", "id" => "invalid" } ], Array.new(501) ].each do |entries|
      expect { described_class.call(result: { "dependencies" => entries }) }.to raise_error(Artifacts::Rejected)
    end
    expect { described_class.model("other") }.to raise_error(Artifacts::Rejected)
  end

  it "bounds combined frame and explicit dependencies after deduplication" do
    entries = Array.new(500) { { "kind" => "native_symbol", "id" => SecureRandom.uuid } }
    expect { described_class.call(result: { "dependencies" => entries, "frames" => [ { "artifact_kind" => "native_symbol", "artifact_id" => SecureRandom.uuid } ] }) }.to raise_error(Artifacts::Rejected)
    [ nil, {}, [ nil ], [ { "artifact_kind" => "other" } ], Array.new(501) ].each do |frames|
      expect { described_class.call(result: { "frames" => frames }) }.to raise_error(Artifacts::Rejected)
    end
    expect(described_class.call(result: { "dependencies" => entries, "frames" => [ { "artifact_kind" => "native_symbol", "artifact_id" => entries.first["id"] } ] })).to eq(entries)
  end
end
