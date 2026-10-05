# frozen_string_literal: true

require "rails_helper"

RSpec.describe Member::Monitoring::SymbolicationPresenter do
  def present(payload: {}, stacktrace: {}, result: {})
    event = Errors::Event.new(payload: payload, stacktrace: stacktrace)
    described_class.new(event: event, result: result)
  end

  it "keeps an unknown original function separate from the mapped callee and generated frame" do
    raw = { "filename" => "app.js", "function" => "a", "lineno" => 1, "colno" => 9 }
    view = present(payload: { "platform" => "javascript" }, stacktrace: { "frames" => [ raw ] },
      result: { "status" => "resolved", "frames" => [ { "index" => 0, "exception_index" => nil, "status" => "mapped", "original" => { "filename" => "source.ts", "lineno" => 7, "colno" => 10, "function" => nil }, "mapped_name" => "callee" } ] })
    row = view.rows.sole
    expect(row[:original]["function"]).to be_nil
    expect(row[:mapped_name]).to eq("callee")
    expect(row[:received]).to eq(raw)
  end

  it "preserves every Java alternative and inline line without choosing one" do
    alternatives = [ { "lines" => [ "at A.first(A.java:1)", "at A.second(A.java:2)" ] }, { "lines" => [ "at B.other(B.java:3)" ] } ]
    view = present(payload: { "platform" => "java" }, result: { "kind" => "proguard", "status" => "partial", "groups" => [ { "kind" => "frame", "status" => "ambiguous", "exception_index" => 0, "frame_index" => 0, "alternatives" => alternatives } ] })
    expect(view.rows.sole[:alternatives]).to eq(alternatives)
    expect(view.java?).to be(true)
  end

  it "does not expose source-map controls for unrelated pending native events" do
    expect(present(payload: { "platform" => "ruby" }, result: { "status" => "pending" }).applicable?).to be(false)
    expect(present(payload: { "platform" => "node" }, result: { "status" => "pending" }).applicable?).to be(true)
  end

  it "does not offer source maps for completed Ruby or Python attempts" do
    result = { "status" => "unresolved", "reason" => "missing_artifact", "frames" => [ { "status" => "missing_artifact" } ] }
    %w[ruby python].each do |platform|
      expect(present(payload: { "platform" => platform }, result: result).applicable?).to be(false)
    end
    expect(present(result: { "frames" => [ { "status" => "mapped" } ] }).applicable?).to be(true)
    expect(present(result: result).applicable?).to be(false)
  end

  it "uses native controls for native events and actual native results without offering source maps" do
    view = present(payload: { "platform" => "native" }, result: { "status" => "pending" })
    expect(view.applicable?).to be(true)
    expect(view.native?).to be(true)
    expect(view.command).to eq("cyi artifacts native-symbols upload --help")
    expect(present(payload: { "platform" => "java" }, result: { "kind" => "native" }).native?).to be(true)
  end

  it "handles unsupported exception shapes without shifting original indices" do
    view = present(payload: { "platform" => "java", "exception" => { "values" => [ 42, { "type" => "Outer", "stacktrace" => "invalid" } ] } })
    expect(view.received_java).to eq([])
    expect(view.exceptions[1]["type"]).to eq("Outer")
    expect(view.exception_frames(view.exceptions[1])).to eq([])
    expect(described_class.frames({ "frames" => [ 42, { "function" => "valid" } ] })).to eq([ { "function" => "valid" } ])
  end

  it "includes exception frames using their original indices without merging causes" do
    view = present(payload: { "platform" => "node", "exception" => { "values" => [ { "type" => "Inner", "stacktrace" => { "frames" => [ { "function" => "inner" } ] } }, { "type" => "Outer", "stacktrace" => { "frames" => [ { "function" => "outer" } ] } } ] } },
      result: { "frames" => [ { "index" => 0, "exception_index" => 0, "status" => "missing_artifact" }, { "index" => 0, "exception_index" => 1, "status" => "unmapped" } ] })
    expect(view.rows.map { |row| row[:exception] }).to eq([ "Inner", "Outer" ])
    expect(view.rows.map { |row| row[:received]["function"] }).to eq(%w[inner outer])
  end
end
