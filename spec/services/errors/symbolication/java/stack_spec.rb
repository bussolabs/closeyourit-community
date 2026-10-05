# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Symbolication::Java::Stack do
  def exception(id:, parent: nil, mechanism: "generic", frames: [])
    { "type" => "IllegalStateException", "module" => "java.lang", "value" => "private message",
      "mechanism" => { "type" => mechanism, "exception_id" => id, "parent_id" => parent },
      "stacktrace" => { "frames" => frames } }
  end

  it "preserves original indices while assembling cause and suppressed context without messages" do
    frame = { "module" => "proof.Crash", "function" => "main", "filename" => "Crash.java", "lineno" => 2 }
    values = [ exception(id: 2, parent: 0), exception(id: 1, parent: 0, mechanism: "suppressed"), exception(id: 0, frames: [ frame ]) ]
    result = described_class.call(values: values)
    expect(result.map { |row| row.fetch("line") }).to eq([ "java.lang.IllegalStateException", "\tat proof.Crash.main(Crash.java:2)", "\tSuppressed: java.lang.IllegalStateException", "Caused by: java.lang.IllegalStateException" ])
    expect(result.map { |row| row["exception_index"] }).to eq([ 2, 2, 1, 0 ])
    expect(result[1]["frame_index"]).to eq(0)
    expect(result.to_json).not_to include("private message")
  end

  it "rejects cycles, duplicate IDs and ambiguous parentage without guessing" do
    expect { described_class.call(values: [ exception(id: 0, parent: 1), exception(id: 1, parent: 0) ]) }.to raise_error(Artifacts::Rejected)
    expect { described_class.call(values: [ exception(id: 0), exception(id: 0) ]) }.to raise_error(Artifacts::Rejected)
    expect { described_class.call(values: [ exception(id: 0), exception(id: 1, parent: 9) ]) }.to raise_error(Artifacts::Rejected)
  end

  it "preserves Android SDK positions when the generated filename is absent" do
    frame = { "module" => "proof.Crash", "function" => "main", "filename" => nil, "lineno" => 7 }
    result = described_class.call(values: [ exception(id: 0, frames: [ frame ]) ])
    expect(result.last.fetch("line")).to eq("\tat proof.Crash.main(Unknown Source:7)")
    frame["lineno"] = 7.5
    expect { described_class.call(values: [ exception(id: 0, frames: [ frame ]) ]) }.to raise_error(Artifacts::Rejected)
  end

  it "is independent of the SDK exception array ordering when mechanism IDs are present" do
    values = [ exception(id: 0), exception(id: 1, parent: 0) ]
    forward = described_class.call(values: values)
    backward = described_class.call(values: values.reverse)
    expect(forward.map { |row| row["line"] }).to eq(backward.map { |row| row["line"] })
    expect(forward.map { |row| row["exception_index"] }).to eq([ 0, 1 ])
    expect(backward.map { |row| row["exception_index"] }).to eq([ 1, 0 ])
  end

  it "bounds full stacks including exception headers and rejects unsupported middle frames" do
    frame = { "module" => "proof.Crash", "function" => "main", "filename" => nil }
    expect(described_class.call(values: [ exception(id: 0, frames: [ frame ] * 499) ]).size).to eq(500)
    expect { described_class.call(values: [ exception(id: 0, frames: [ frame ] * 500) ]) }.to raise_error(Artifacts::Rejected)
    expect { described_class.call(values: [ exception(id: 0, frames: [ frame, { "module" => "bad\nInjected" }, frame ]) ]) }.to raise_error(Artifacts::Rejected)
  end
end
