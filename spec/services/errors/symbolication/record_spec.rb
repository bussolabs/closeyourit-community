# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Symbolication::Record do
  let(:project) { create(:project) }
  let(:account) { create(:account) }
  let(:frame) { { "filename" => "https://example.test/app.js", "lineno" => 1, "colno" => 1, "function" => "a" } }
  let(:payload) { { "event_id" => "a" * 32, "release" => "v1", "platform" => "javascript", "exception" => { "values" => [ { "type" => "Error", "value" => "failure", "stacktrace" => { "frames" => [ frame ] } } ] } } }
  let(:event) { Errors::Ingest::Record.call(project: project, payload: payload).value }
  let(:range) { { "source_index" => 0, "start_line" => 0, "start_column" => 0, "end_line" => 4, "end_column" => 0, "name" => "originalBoundary" } }
  let(:map) { { "version" => 3, "sources" => [ "source.ts" ], "names" => [ "calledFunction" ], "mappings" => "AAAAA", "x_closeyourit_functions" => { "version" => 1, "ranges" => [ range ] } } }

  def upload(metadata = {})
    Artifacts::SourceMaps::Upload.call(project: project, account: account, metadata: { "release" => "v1", "generated_file" => frame["filename"] }.merge(metadata), map: map).artifact
  end

  it "resolves after late upload without changing original evidence or grouping" do
    before = event.attributes.slice("payload", "stacktrace", "group_id")
    result = described_class.call(event: event)
    expect(result.result["frames"].first["status"]).to eq("missing_artifact")
    artifact = upload
    result = described_class.call(event: event).result
    row = result["frames"].find { |value| value["exception_index"].nil? }
    expect(row).to include("status" => "mapped", "artifact_id" => artifact.id, "mapped_name" => "calledFunction")
    expect(row["original"]).to include("filename" => "source.ts", "lineno" => 1, "colno" => 1, "function" => "originalBoundary")
    expect(event.reload.attributes.slice("payload", "stacktrace", "group_id")).to eq(before)
    expect(artifact.reload.unreferenced_since).to be_nil
    expect(Artifacts::Reference.where(source_map_id: artifact.id).count).to eq(1)
  end

  it "never applies a different release, distribution or debug identity" do
    upload("dist" => "other")
    expect(described_class.call(event: event).result["frames"].first["status"]).to eq("identity_mismatch")
  end

  it "marks original functions unknown when the map only supplies a different symbol name" do
    map.delete("x_closeyourit_functions")
    upload
    result = described_class.call(event: event).result
    expect(result["stacktrace"]["frames"].first["function"]).to be_nil
    expect(event.stacktrace["frames"].first["function"]).to eq("a")
    expect(result["frames"].first["original"].fetch("function")).to be_nil
    expect(result["frames"].first["mapped_name"]).to eq("calledFunction")
  end

  it "respects unmapped segment boundaries and does not infer missing columns" do
    upload
    frame.delete("colno")
    expect(described_class.call(event: event).result["frames"].first["status"]).to eq("missing_position")
    expect(Artifacts::SourceMaps::Lookup.call(map: Artifacts::SourceMaps::Decode.call(map: map.merge("mappings" => "AAAA,K")), line: 0, column: 5)).to be_nil
  end
end
