# frozen_string_literal: true

require "rails_helper"

RSpec.describe Artifacts::BackfillJob do
  include ActiveJob::TestHelper
  it "preserves source map backfill for legacy events without a platform while excluding Java" do
    project = create(:project)
    artifact = Artifacts::SourceMaps::Upload.call(project: project, account: create(:account), metadata: { "release" => "v1", "generated_file" => "app.js" }, map: { "version" => 3, "sources" => [ "source.ts" ], "names" => [], "mappings" => "AAAA" }).artifact
    legacy = create(:error_event, project: project, release: "v1", payload: { "stacktrace" => { "frames" => [ { "filename" => "app.js", "lineno" => 1, "colno" => 1 } ] } })
    java = create(:error_event, project: project, release: "v1", payload: { "platform" => "java" })
    clear_enqueued_jobs
    described_class.perform_now(project_id: project.id, source_map_id: artifact.id)
    arguments = enqueued_jobs.select { |job| job[:job] == Errors::SymbolicateJob }.flat_map { |job| job[:args] }
    expect(arguments.map { |args| args.fetch("event_id") }).to eq([ legacy.id ])
    expect(arguments.to_json).not_to include(java.id)
  end
end
