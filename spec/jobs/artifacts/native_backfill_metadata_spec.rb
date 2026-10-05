# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::NativeBackfillJob do
  include ActiveJob::TestHelper
  around { |example| Time.use_zone("Europe/Rome") { example.run } }
  let(:project) { create(:project) }
  let(:group) { create(:error_group, project: project) }
  let(:manifest) { JSON.parse(Pathname(__dir__).join("../../fixtures/artifacts/linux-arm64-crash-manifest.json").read).fetch("manifest") }
  let(:artifact) do
    proof = JSON.parse(Pathname(__dir__).join("../../fixtures/artifacts/native-processor-response.json").read)
    identity = Artifacts::NativeSymbols::Identity.call(metadata: proof.fetch("response").fetch("objects").first)
    blob = Artifacts::Blob.create!(project_id: project.id, key: "artifacts/#{SecureRandom.hex(32)}", service_name: "test",
      byte_size: 3_656_048, sha256: proof.fetch("input_sha256"), reserved_until: 1.hour.from_now)
    # Backfill selects stored metadata; processor admission is covered separately.
    project.native_symbol_artifacts.create!(**identity, blob: blob, identity_sha256: Digest::SHA256.hexdigest(identity.to_json))
  end

  def event_and_report(at: Time.current)
    event = create(:error_event, project: project, group: group, payload: { "platform" => "native" }, created_at: at)
    report = project.crash_reports.create!(event_id: event.event_id, manifest: manifest, created_at: at)
    [ event, report ]
  end

  def scheduled_events
    enqueued_jobs.select { |job| job[:job] == Errors::SymbolicateJob }.map { |job| job[:args].first.fetch("event_id") }
  end

  it "ignores missing projects, absent symbols and symbols owned by another tenant" do
    own = artifact
    clear_enqueued_jobs
    described_class.perform_now(project_id: SecureRandom.uuid, native_symbol_id: own.id)
    described_class.perform_now(project_id: project.id, native_symbol_id: SecureRandom.uuid)
    described_class.perform_now(project_id: create(:project).id, native_symbol_id: own.id)
    expect(enqueued_jobs).to be_empty
  end

  it "selects only retained reports with the exact build identity" do
    matching, = event_and_report
    _, mismatch = event_and_report
    mismatch.update!(manifest: manifest.merge("modules" => []))
    event_and_report(at: (Errors::Retention.for(project) + 1).days.ago)
    own = artifact
    clear_enqueued_jobs
    described_class.perform_now(project_id: project.id, native_symbol_id: own.id)
    expect(scheduled_events).to eq([ matching.id ])
  end

  it "continues reports at the same timestamp using the offset-aware cursor without repeating events" do
    time = Time.current.change(usec: 123456)
    rows = Array.new(101) { event_and_report(at: time) }.sort_by { |_event, report| report.id }
    own = artifact
    clear_enqueued_jobs
    described_class.perform_now(project_id: project.id, native_symbol_id: own.id)
    expect(scheduled_events).to match_array(rows.first(100).map { |event, _report| event.id })
    args = enqueued_jobs.find { |job| job[:job] == described_class }.fetch(:args).first
    expect(args.fetch("after_id")).to eq(rows[-2].last.id)
    clear_enqueued_jobs
    described_class.perform_now(project_id: project.id, native_symbol_id: own.id, after_time: args.fetch("after_time"), after_id: args.fetch("after_id"))
    expect(scheduled_events).to eq([ rows.last.first.id ])
    expect(enqueued_jobs.none? { |job| job[:job] == described_class }).to be(true)
  end
end
