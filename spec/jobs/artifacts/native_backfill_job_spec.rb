# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::NativeBackfillJob do
  include ActiveJob::TestHelper

  it "backfills retained matching reports only within the artifact project" do
    project = create(:project)
    event = create(:error_event, project: project, payload: { "platform" => "native" })
    other = create(:error_event, payload: { "platform" => "native" })
    expired = create(:error_event, project: project, payload: { "platform" => "native" })
    [ event, other, expired ].each do |entry|
      entry.project.crash_reports.create!(event_id: entry.event_id, manifest: native_fixture.fetch("raw_report"), created_at: entry == expired ? 31.days.ago : Time.current)
    end
    artifact = upload_native(project)
    clear_enqueued_jobs
    described_class.perform_now(project_id: project.id, native_symbol_id: artifact.id)
    arguments = enqueued_jobs.select { |job| job[:job] == Errors::SymbolicateJob }.flat_map { |job| job[:args] }
    expect(arguments.map { |args| args.fetch("event_id") }).to eq([ event.id ])
  end
end
