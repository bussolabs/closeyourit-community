# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Artifact collection concurrency", :real_concurrency do
  self.use_transactional_tests = false

  it "admits only one concurrent upload when the remaining project quota holds one map" do
    organization = create(:organization, slug: "artifacts-#{SecureRandom.hex(8)}")
    project = create(:project, organization: organization)
    account = create(:account)
    map = { "version" => 3, "sources" => [ "source.ts" ], "names" => [], "mappings" => "AAAA" }
    size = Artifacts::SourceMaps::Decode.call(map: map).to_json.bytesize
    20.times do |index|
      Artifacts::Blob.create!(project_id: project.id, key: "artifacts/#{SecureRandom.hex(32)}", service_name: "test",
        byte_size: Artifacts::MAX_MAP - (index.zero? ? size : 0), sha256: "a" * 64, reserved_until: 1.hour.from_now)
    end
    ready, proceed = Queue.new, Queue.new
    threads = 2.times.map do |index|
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ready << true
          proceed.pop
          Artifacts::SourceMaps::Upload.call(project: Projects::Project.find(project.id), account: account,
            metadata: { "release" => "v1", "generated_file" => "app#{index}.js" }, map: map)
          :accepted
        rescue Artifacts::Rejected => error
          error.message
        end
      end
    end
    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { proceed << true }
    expect(threads.map(&:value)).to contain_exactly(:accepted, "project_artifact_quota")
    expect(project.source_map_artifacts.count).to eq(1)
    expect(Artifacts::Blob.where(project_id: project.id).sum(:byte_size)).to eq(Artifacts::MAX_PROJECT_BYTES)
  ensure
    2.times { proceed << true } if proceed
    threads&.each(&:join)
    organization&.destroy!
    Artifacts::PruneJob.perform_now(project_id: project.id) if project
    account&.destroy!
  end

  it "allows two collectors to purge the same loaded lifecycle row idempotently" do
    organization = create(:organization, slug: "artifacts-#{SecureRandom.hex(8)}")
    project = create(:project, organization: organization)
    blob = Artifacts::Blob.create!(project_id: project.id, key: "artifacts/#{SecureRandom.hex(32)}",
      service_name: "test", byte_size: 3, sha256: Digest::SHA256.hexdigest("abc"), reserved_until: 1.minute.ago)
    blob.service.upload(blob.key, StringIO.new("abc"))
    ready, proceed = Queue.new, Queue.new
    allow_any_instance_of(Artifacts::Blob).to receive(:with_lock).and_wrap_original do |method, *args, &block|
      ready << true
      proceed.pop
      method.call(*args, &block)
    end
    threads = 2.times.map do
      Thread.new do
        ApplicationRecord.connection_pool.with_connection { Artifacts::PruneJob.perform_now(project_id: project.id) }
      end
    end
    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { proceed << true }
    threads.each(&:value)
    expect(Artifacts::Blob.exists?(blob.id)).to be(false)
    expect(blob.service.exist?(blob.key)).to be(false)
  ensure
    2.times { proceed << true } if proceed
    threads&.each(&:join)
    organization&.destroy!
  end
end
