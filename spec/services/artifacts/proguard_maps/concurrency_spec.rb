# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Shared artifact admission", :real_concurrency do
  self.use_transactional_tests = false

  it "serializes source map and ProGuard admissions against the same remaining quota" do
    skip "Set RETRACE_PROCESSOR_URL to the owned isolated processor" if ENV["RETRACE_PROCESSOR_URL"].blank?
    organization = create(:organization, slug: "proguard-#{SecureRandom.hex(8)}")
    project = create(:project, organization: organization)
    account = create(:account)
    mapping = Rails.root.join("spec/fixtures/artifacts/r8-9.4.28-mapping.txt").read
    map = { "version" => 3, "sources" => [ "source.ts" ], "names" => [], "mappings" => "AAAA" }
    available = [ Artifacts::SourceMaps::Decode.call(map: map).to_json.bytesize, mapping.bytesize ].max
    20.times do |index|
      Artifacts::Blob.create!(project_id: project.id, key: "artifacts/#{SecureRandom.hex(32)}", service_name: "test", byte_size: Artifacts::MAX_MAP - (index.zero? ? available : 0), sha256: "a" * 64, reserved_until: 1.hour.from_now)
    end
    ready, proceed = Queue.new, Queue.new
    operations = [
      ->(owner) { Artifacts::SourceMaps::Upload.call(project: owner, account: account, metadata: { "release" => "v1", "generated_file" => "app.js" }, map: map) },
      ->(owner) { Artifacts::ProguardMaps::Upload.call(project: owner, account: account, metadata: { "release" => "v1", "debug_id" => SecureRandom.uuid }, mapping: mapping) }
    ]
    threads = operations.map do |operation|
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ready << true
          proceed.pop
          operation.call(Projects::Project.find(project.id))
          :accepted
        rescue Artifacts::Rejected => error
          error.message
        end
      end
    end
    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { proceed << true }
    expect(threads.map(&:value)).to contain_exactly(:accepted, "project_artifact_quota")
    expect(project.source_map_artifacts.count + project.proguard_map_artifacts.count).to eq(1)
    expect(Artifacts::Blob.where(project_id: project.id).sum(:byte_size)).to be <= Artifacts::MAX_PROJECT_BYTES
  ensure
    2.times { proceed << true } if proceed
    threads&.each(&:join)
    organization&.destroy!
    Artifacts::PruneJob.perform_now(project_id: project.id) if project
    account&.destroy!
  end
end
