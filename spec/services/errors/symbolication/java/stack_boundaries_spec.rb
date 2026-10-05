# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Symbolication::Java::Stack, "protocol boundaries" do
  def exception(id: 0, parent: nil)
    { "type" => "java.lang.IllegalStateException",
      "mechanism" => { "exception_id" => id, "parent_id" => parent },
      "stacktrace" => { "frames" => [] } }
  end

  def frame(**values)
    { "module" => "proof.Crash", "function" => "main", "filename" => "Crash.java" }.merge(values.stringify_keys)
  end

  def stack_with(value)
    row = exception
    row["stacktrace"]["frames"] = [ value ]
    described_class.call(values: [ row ])
  end

  it "preserves native methods, static initializers and filenames without line numbers" do
    expect(stack_with(frame(native: true)).last["line"]).to eq("\tat proof.Crash.main(Native Method)")
    expect(stack_with(frame(function: "<clinit>")).last["line"]).to eq("\tat proof.Crash.<clinit>(Crash.java)")
    expect(stack_with(frame(function: "<init>", lineno: 0)).last["line"]).to eq("\tat proof.Crash.<init>(Crash.java:0)")
  end

  it "accepts legacy cause chains only when mechanisms are consistently absent" do
    values = [ exception(id: nil), exception(id: nil) ]
    result = described_class.call(values: values)
    expect(result.map { |row| row["exception_index"] }).to eq([ 1, 0 ])
    expect(result.last["line"]).to start_with("Caused by: ")
    values.first["mechanism"]["parent_id"] = 0
    expect { described_class.call(values: values) }.to raise_error(Artifacts::Rejected)
    expect { described_class.call(values: [ exception, exception(id: nil) ]) }.to raise_error(Artifacts::Rejected)
  end

  it "rejects invalid graph structure instead of returning a truncated chain" do
    [ nil, [], [ nil ], [ exception ] * 101 ].each do |values|
      expect { described_class.call(values: values) }.to raise_error(Artifacts::Rejected)
    end
    expect { described_class.call(values: [ exception, exception(id: 1, parent: 0), exception(id: 2, parent: 0) ]) }.to raise_error(Artifacts::Rejected)
    root = exception
    root["mechanism"]["type"] = "suppressed"
    expect { described_class.call(values: [ root ]) }.to raise_error(Artifacts::Rejected)
  end

  it "bounds nested causes at 32 levels" do
    values = (0..32).map { |id| exception(id: id, parent: id.zero? ? nil : id - 1) }
    expect(described_class.call(values: values).size).to eq(33)
    expect { described_class.call(values: values + [ exception(id: 33, parent: 32) ]) }.to raise_error(Artifacts::Rejected)
  end

  it "rejects malformed mechanisms and stack containers" do
    [ { "mechanism" => [] }, { "stacktrace" => nil }, { "stacktrace" => { "frames" => {} } } ].each do |change|
      expect { described_class.call(values: [ exception.merge(change) ]) }.to raise_error(Artifacts::Rejected)
    end
    [ -1, 2**31, 1.5 ].each do |id|
      expect { described_class.call(values: [ exception(id: id) ]) }.to raise_error(Artifacts::Rejected)
    end
  end

  it "rejects injected or oversized source names and invalid frames" do
    [ nil, frame(function: nil), frame(filename: "x\nInjected"), frame(filename: "x" * 2049),
      frame(filename: 3), frame(filename: "\xff".dup.force_encoding(Encoding::UTF_8)), frame(module: "x" * 2049), frame(lineno: -1) ].each do |value|
      expect { stack_with(value) }.to raise_error(Artifacts::Rejected)
    end
    expect { stack_with(frame(module: "x" * 2048, function: "x" * 2048)) }.to raise_error(Artifacts::Rejected)
  end

  it "does not prefix a fully qualified exception type twice" do
    row = exception.merge("module" => "java.lang")
    expect(described_class.call(values: [ row ]).first["line"]).to eq("java.lang.IllegalStateException")
  end
end
