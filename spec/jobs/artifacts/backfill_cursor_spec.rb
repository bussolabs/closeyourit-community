# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Artifact backfill cursors" do
  include ActiveJob::TestHelper

  it "compares a negative-offset source map cursor as an instant, without replaying the first batch" do
    Time.use_zone("America/New_York") do
      project = create(:project)
      group = create(:error_group, project: project)
      map = JSON.parse(Rails.root.join("spec/fixtures/artifacts/source_maps/nuxt_4_5_2_index.json").read)
      artifact = Artifacts::SourceMaps::Upload.call(project: project, account: nil,
        metadata: { "release" => "v1", "generated_file" => map.fetch("file") }, map: map).artifact
      time = Time.current.change(usec: 123456)
      ids = Array.new(101) do
        create(:error_event, project: project, group: group, release: "v1", created_at: time).id
      end.sort
      clear_enqueued_jobs
      Artifacts::BackfillJob.perform_now(project_id: project.id, source_map_id: artifact.id)
      cursor = enqueued_jobs.find { |job| job[:job] == Artifacts::BackfillJob }[:args].first
      expect(Time.iso8601(cursor.fetch("after_time")).utc_offset).to be < 0
      clear_enqueued_jobs
      Artifacts::BackfillJob.perform_now(project_id: project.id, source_map_id: artifact.id,
        after_time: cursor.fetch("after_time"), after_id: cursor.fetch("after_id"))
      expect(enqueued_jobs.select { |job| job[:job] == Errors::SymbolicateJob }.map { |job| job[:args].first.fetch("event_id") }).to eq([ ids.last ])
      expect(enqueued_jobs.none? { |job| job[:job] == Artifacts::BackfillJob }).to be(true)
    end
  end

  it "continues native reports at a positive-offset cursor without losing the last report" do
    Time.use_zone("Europe/Rome") do
      project = create(:project)
      group = create(:error_group, project: project)
      artifact = upload_native(project)
      time = Time.current.change(usec: 654321)
      entries = Array.new(101) do
        event = create(:error_event, project: project, group: group, payload: { "platform" => "native" }, created_at: time)
        report = project.crash_reports.create!(event_id: event.event_id, manifest: native_fixture.fetch("raw_report"), created_at: time)
        [ report.id, event.id ]
      end.sort
      clear_enqueued_jobs
      Artifacts::NativeBackfillJob.perform_now(project_id: project.id, native_symbol_id: artifact.id)
      cursor = enqueued_jobs.find { |job| job[:job] == Artifacts::NativeBackfillJob }[:args].first
      expect(Time.iso8601(cursor.fetch("after_time")).utc_offset).to be > 0
      clear_enqueued_jobs
      Artifacts::NativeBackfillJob.perform_now(project_id: project.id, native_symbol_id: artifact.id,
        after_time: cursor.fetch("after_time"), after_id: cursor.fetch("after_id"))
      expect(enqueued_jobs.select { |job| job[:job] == Errors::SymbolicateJob }.map { |job| job[:args].first.fetch("event_id") }).to eq([ entries.last.last ])
      expect(enqueued_jobs.none? { |job| job[:job] == Artifacts::NativeBackfillJob }).to be(true)
    end
  end
end
