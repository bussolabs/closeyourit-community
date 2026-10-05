# frozen_string_literal: true

require "rails_helper"

RSpec.describe Member::Monitoring::NativeSymbolicationPresenter do
  let(:manifest) do
    { "crash_info" => { "crashing_thread" => 1 }, "modules" => [ { "filename" => "program", "debug_id" => "a" * 32, "code_id" => "b" * 40 } ],
      "threads" => [ { "thread_id" => 20, "frames" => [] }, { "thread_id" => 91,
        "frames" => [ { "instruction" => "0x1234", "module_offset" => "0x234", "trust" => "context" } ] } ] }
  end
  let(:source) { { "id" => "report", "manifest" => manifest, "manifest_sha256" => Errors::Symbolication::Native::Source.digest(manifest) } }
  let(:locations) { [ { "function" => "inner", "file" => "source.c", "line" => 0 }, { "function" => "caller", "line" => nil } ] }
  let(:result) do
    { "kind" => "native", "status" => "partial", "native" => { "report_id" => source["id"], "manifest_sha256" => source["manifest_sha256"] },
      "frames" => [ { "thread_index" => 1, "frame_index" => 0, "module_index" => 0, "status" => "resolved", "locations" => locations } ] }
  end

  it "preserves actual thread IDs, raw addresses, trust and innermost-first inline locations" do
    view = described_class.new(result: result, report: source)
    expect(view.threads.map { |thread| thread[:id] }).to eq([ 20, 91 ])
    expect(view.selected_thread).to eq(1)
    frame = view.threads.last[:frames].sole
    expect(frame[:received]).to eq(manifest["threads"][1]["frames"][0])
    expect(frame[:locations]).to eq(locations)
    expect(frame[:module]).to eq(manifest["modules"].sole)
  end

  it "keeps received addresses without resurrecting deleted derived frames" do
    view = described_class.new(result: { "reason" => "artifact_deleted", "frames" => [] }, report: source)
    expect(view.threads.last[:frames].sole[:locations]).to eq([])
    expect(view.threads.last[:frames].sole[:received]["instruction"]).to eq("0x1234")
  end

  it "does not join results to a changed manifest or invent a missing report" do
    view = described_class.new(result: result.deep_merge("native" => { "manifest_sha256" => "wrong" }), report: source)
    expect(view.reason).to eq("crash_report_unavailable")
    expect(view.threads.last[:frames].sole[:locations]).to eq([])
    expect(described_class.new(result: result, report: nil).threads).to eq([])
  end

  it "keeps ambiguous module frames unresolved without choosing an arbitrary module" do
    value = result.deep_dup
    value["frames"][0] = { "thread_index" => 1, "frame_index" => 0, "status" => "ambiguous_module", "locations" => [] }
    frame = described_class.new(result: value, report: source).threads.last[:frames].sole
    expect(frame[:module]).to be_nil
    expect(frame[:status]).to eq("ambiguous_module")
  end

  it "admits exactly 500 received frames and rejects the entire page projection above that limit" do
    manifest["threads"][1]["frames"] = Array.new(500) { { "instruction" => "0x1234" } }
    view = described_class.new(result: { "status" => "unresolved", "frames" => [] }, report: source)
    expect(view.threads.sum { |thread| thread[:frames].size }).to eq(500)
    manifest["threads"][0]["frames"] = [ { "instruction" => "0x5678" } ]
    over = described_class.new(result: { "status" => "partial", "frames" => [] }, report: source)
    expect(over.threads).to eq([])
    expect(over.reason).to eq("native_source_budget")
    expect(over.status).to eq("unresolved")
  end

  it "preserves thread, frame and module indices when malformed entries are skipped" do
    manifest["threads"][0] = nil
    manifest["threads"][1]["frames"].unshift(nil)
    manifest["modules"].unshift(nil)
    result["frames"][0].merge!("frame_index" => 1, "module_index" => 1)
    view = described_class.new(result: result, report: source)
    expect(view.selected_thread).to eq(1)
    frame = view.threads.sole[:frames].sole
    expect(frame[:index]).to eq(1)
    expect(frame[:locations]).to eq(locations)
    expect(frame[:module]["filename"]).to eq("program")
  end
end
