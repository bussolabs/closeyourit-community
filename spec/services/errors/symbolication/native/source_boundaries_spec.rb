# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Symbolication::Native::Source do
  let(:project) { create(:project) }
  let(:event) { create(:error_event, project: project, release: "v1") }
  let(:manifest) { JSON.parse(Pathname(__dir__).join("../../../../fixtures/artifacts/linux-arm64-crash-manifest.json").read).fetch("manifest") }
  let(:report) { project.crash_reports.create!(event_id: event.event_id, release: "v1", manifest: manifest) }
  let(:source) { { "kind" => "native", "native" => { "report_id" => report.id, "manifest_sha256" => described_class.digest(manifest) } } }

  it "finds and validates only the retained report for the same event" do
    report
    expect(described_class.find(event)).to eq(report)
    expect(described_class.validate!(event, source)).to eq(crash_report_id: report.id, manifest_sha256: described_class.digest(manifest))
    expect(described_class.available([ event ])).to eq([ project.id, event.event_id ] => source["native"])
    expect(described_class.available([])).to eq({})
    expect(described_class.validate!(event, { "kind" => "proguard" })).to eq({})
    expect(described_class.validate!(event, { "kind" => "native" })).to eq({})
  end

  it "rejects a changed or deleted report instead of reusing stale reconstruction" do
    original = source
    report.update!(manifest: manifest.merge("crash_info" => {}))
    expect { described_class.validate!(event, original) }.to raise_error(Artifacts::Unavailable, /changed/)
    report.destroy!
    expect { described_class.validate!(event, original) }.to raise_error(Artifacts::Unavailable, /changed/)
  end

  it "does not resolve expired events or return their crash source" do
    report
    original = source
    event.created_at = Errors::Retention.for(project).days.ago - 1.second
    expect(described_class.find(event)).to be_nil
    expect(described_class.available([ event ])).to eq({})
    expect { described_class.validate!(event, original) }.to raise_error(Artifacts::Unavailable, /expired/)
  end

  it "rejects oversized retained manifests before reading them into the result" do
    report.update!(manifest: manifest.merge("unexpected" => "x" * (5.megabytes + 1)))
    expect { described_class.available([ event ]) }.to raise_error(Artifacts::Rejected, "native_source_budget")
  end

  it "keeps missing artifacts and invalid stack addresses unresolved with their real report identity" do
    report
    result = Errors::Symbolication::Native::Resolve.call(event: event)
    expect(result).to include("kind" => "native", "status" => "unresolved")
    expect(result.fetch("frames").map { |frame| frame["status"] }).to include("missing_artifact")
    expect(result.fetch("native")).to include(source.fetch("native"))
    manifest.fetch("threads").first.fetch("frames").first["instruction"] = "invalid"
    report.update!(manifest: manifest)
    expect(Errors::Symbolication::Native::Resolve.call(event: event).fetch("frames").first["status"]).to eq("invalid_address")
  end

  it "bounds stack size and returns an explicit missing report outcome" do
    report
    manifest.fetch("threads").first["frames"] = [ manifest.fetch("threads").first.fetch("frames").first ] * 501
    report.update!(manifest: manifest)
    expect(Errors::Symbolication::Native::Resolve.call(event: event)).to include("reason" => "native_budget", "retryable" => false)
    report.destroy!
    expect(Errors::Symbolication::Native::Resolve.call(event: event)).to include("reason" => "crash_report_unavailable")
  end
  it "persists native reconstruction and discards work for a deleted event" do
    report
    record = Errors::Symbolication::Record.call(event: event)
    expect(record).to have_attributes(crash_report_id: report.id, manifest_sha256: described_class.digest(manifest))
    expect(record.result).to include("kind" => "native", "status" => "unresolved")
    event.destroy!
    expect(Errors::Symbolication::Record.call(event: event)).to be_nil
  end

  it "separates unique artifact matches from ambiguous build metadata" do
    resolver = Errors::Symbolication::Native::Resolve.new(event: event)
    frames = Errors::Symbolication::Native::Stack.call(manifest: manifest)
    identity = frames.find { |frame| frame["identity"] }.fetch("identity")
    first = Artifacts::NativeSymbol.new(**identity, id: SecureRandom.uuid)
    second = Artifacts::NativeSymbol.new(**identity, id: SecureRandom.uuid)
    resolver.instance_variable_set(:@frames, frames.deep_dup)
    expect(resolver.send(:select_artifacts, [ first ]).map(&:last)).to include(first)
    resolver.instance_variable_set(:@frames, frames.deep_dup)
    expect(resolver.send(:select_artifacts, [ first, second ])).to be_empty
    expect(resolver.instance_variable_get(:@frames).map { |frame| frame["status"] }).to include("ambiguous_artifact")
  end
end
