# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Java reconstruction with official R8" do
  let(:project) { create(:project) }
  let(:account) { create(:account) }
  let(:debug_id) { "3c4f2c60-06dc-4d5c-8c08-521d6d8ebaa2" }
  let(:mapping) { Rails.root.join("spec/fixtures/artifacts/r8-9.4.28-mapping.txt").read }
  let(:artifact) { Artifacts::ProguardMaps::Upload.call(project: project, account: account, metadata: { "release" => "v1", "debug_id" => debug_id }, mapping: mapping).artifact }
  let(:payload) do
    { "event_id" => SecureRandom.hex(16), "release" => "v1", "platform" => "java",
      "debug_meta" => { "images" => [ { "type" => "proguard", "uuid" => debug_id } ] },
      "exception" => { "values" => [ { "type" => "IllegalArgumentException", "module" => "java.lang", "value" => "failure",
        "mechanism" => { "exception_id" => 0 }, "stacktrace" => { "frames" => [
          { "module" => "Caller", "function" => "main", "filename" => "Caller.java", "lineno" => 9 },
          { "module" => "proof.Crash", "function" => "main", "filename" => "r8-map-id-827322f", "lineno" => 1 }
        ] } } ] } }
  end
  let(:event) { Errors::Ingest::Record.call(project: project, payload: payload).value }

  before { skip "Set RETRACE_PROCESSOR_URL to the owned isolated processor" if ENV["RETRACE_PROCESSOR_URL"].blank? }

  it "expands an actual inline mapping and preserves the original evidence and unmapped caller" do
    artifact
    original = event.reload.attributes
    record = Errors::Symbolication::Record.call(event: event)
    result = record.result
    expect(result).to include("kind" => "proguard", "status" => "partial")
    frame = result.fetch("frames").find { |row| row["frame_index"] == 1 }
    expect(frame).to include("status" => "mapped", "exception_index" => 0)
    expect(frame.fetch("alternatives").sole.fetch("lines")).to eq([ "\tat proof.Crash.leaf(Crash.java:4)", "\tat proof.Crash.boundary(Crash.java:7)", "\tat proof.Crash.main(Crash.java:9)" ])
    expect(result.fetch("frames").find { |row| row["frame_index"] == 0 }.fetch("status")).to eq("unmapped")
    expect(event.reload.attributes).to eq(original)
    expect(record.artifact_references.sole.proguard_map_id).to eq(artifact.id)
    expect(artifact.reload.unreferenced_since).to be_nil
    artifact.destroy!
    value = Errors::Symbolication::Read.call(events: [ event ]).values.sole
    expect(value.fetch("reason")).to eq("artifact_deleted")
  end

  it "keeps dependencies when only an exception header was consumed" do
    artifact
    payload.fetch("exception").fetch("values").first["stacktrace"] = { "frames" => [] }
    record = Errors::Symbolication::Record.call(event: event)
    expect(record.result.fetch("frames")).to eq([])
    expect(record.artifact_references.sole.proguard_map_id).to eq(artifact.id)
    artifact.destroy!
    expect(Errors::Symbolication::Read.call(events: [ event ]).values.sole.fetch("reason")).to eq("artifact_deleted")
  end

  it "never falls back across missing, conflicting or mismatched build identities" do
    artifact
    payload["dist"] = "other"
    expect(Errors::Symbolication::Resolve.call(event: event).fetch("reason")).to eq("identity_mismatch")
    payload["debug_meta"]["images"] << { "type" => "proguard", "uuid" => SecureRandom.uuid }
    another = Errors::Ingest::Record.call(project: project, payload: payload.merge("event_id" => SecureRandom.hex(16))).value
    expect(Errors::Symbolication::Resolve.call(event: another).fetch("reason")).to eq("identity_mismatch")
  end

  it "persists an explicit unavailable result while scheduling a real job retry" do
    artifact
    event
    original = ENV.delete("RETRACE_PROCESSOR_URL")
    expect do
      Errors::SymbolicateJob.perform_now(project_id: project.id, event_id: event.id, event_created_at: event.created_at.iso8601(6))
    end.to have_enqueued_job(Errors::SymbolicateJob)
    expect(Errors::Symbolication::Read.call(events: [ event ]).values.sole).to include("reason" => "processing_unavailable", "retryable" => true)
  ensure
    ENV["RETRACE_PROCESSOR_URL"] = original if original
  end
end
