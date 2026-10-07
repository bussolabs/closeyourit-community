# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::ProguardMaps::Processor do
  it "fails closed when no private processor is configured" do
    original = ENV.delete("RETRACE_PROCESSOR_URL")
    expect { described_class.call(mapping: "example.Type -> a:\n", stacktrace: []) }.to raise_error(Artifacts::Unavailable)
  ensure
    ENV["RETRACE_PROCESSOR_URL"] = original if original
  end

  it "rejects invalid Unicode and line injection before a processor request" do
    expect { described_class.call(mapping: "\xff".b, stacktrace: []) }.to raise_error(Artifacts::Rejected)
    expect { described_class.call(mapping: "example.Type -> a:\n", stacktrace: [ "a\nb" ]) }.to raise_error(Artifacts::Rejected)
    expect { described_class.call(mapping: "example.Type -> a:\n", stacktrace: [ "a" ] * 501) }.to raise_error(Artifacts::Rejected)
  end

  it "accepts eight MiB mappings and rejects the next byte before network access" do
    mapping = "example.Type -> a:\n".ljust(8.megabytes, " ")
    processor = described_class.new(mapping: mapping, stacktrace: [])
    expect { processor.send(:validate_input!) }.not_to raise_error
    oversized = described_class.new(mapping: mapping + " ", stacktrace: [])
    expect { oversized.send(:validate_input!) }.to raise_error(Artifacts::Rejected, "invalid_mapping")
  end

  it "requires integer protocol fields and coherent ambiguity" do
    processor = described_class.new(mapping: "example.Type -> a:\n", stacktrace: [ "a" ])
    group = { "index" => 0, "ambiguous" => false, "alternatives" => [ { "lines" => [ "a" ] } ] }
    expect { processor.send(:validate_response!, { "schema_version" => 1.0, "groups" => [ group ] }) }.to raise_error(Artifacts::Unavailable)
    expect { processor.send(:validate_response!, { "schema_version" => 1, "groups" => [ group.merge("index" => 0.0) ] }) }.to raise_error(Artifacts::Unavailable)
    expect { processor.send(:validate_response!, { "schema_version" => 1, "groups" => [ group.merge("alternatives" => [ { "lines" => [ "a" ] }, { "lines" => [ "b" ] } ]) ] }) }.to raise_error(Artifacts::Unavailable)
  end
end
