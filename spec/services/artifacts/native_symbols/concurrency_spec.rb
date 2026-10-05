# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Native artifact admission", :real_concurrency do
  self.use_transactional_tests = false

  it "serializes native and source map reservations against their shared remaining quota" do
    bytes = native_bytes
    metadata = native_fixture.fetch("symbols")
    organization = create(:organization, slug: "native-#{SecureRandom.hex(8)}")
    project = create(:project, organization: organization)
    account = create(:account)
    20.times do |index|
      Artifacts::Blob.create!(project_id: project.id, key: "artifacts/#{SecureRandom.hex(32)}", service_name: "test", byte_size: Artifacts::MAX_MAP - (index.zero? ? bytes.bytesize : 0), sha256: "a" * 64, reserved_until: 1.hour.from_now)
    end
    ready, proceed = Queue.new, Queue.new
    operations = [
      ->(owner) { Artifacts::SourceMaps::Upload.call(project: owner, account: account, metadata: { "release" => "v1", "generated_file" => "app.js" }, map: { "version" => 3, "sources" => [ "source.ts" ], "names" => [], "mappings" => "AAAA" }) },
      ->(owner) { Artifacts::NativeSymbols::Upload.call(project: owner, account: account, metadata: metadata, object_base64: Base64.strict_encode64(bytes)) }
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
    expect(project.source_map_artifacts.count + project.native_symbol_artifacts.count).to eq(1)
    expect(Artifacts::Blob.where(project_id: project.id).sum(:byte_size)).to be <= Artifacts::MAX_PROJECT_BYTES
  ensure
    2.times { proceed << true } if proceed
    threads&.each(&:join)
    organization&.destroy!
    Artifacts::PruneJob.perform_now(project_id: project.id) if project
    account&.destroy!
  end

  it "keeps lifecycle ownership while tenant deletion races an unfinished object upload" do
    bytes = native_bytes
    metadata = native_fixture.fetch("symbols")
    organization = create(:organization, slug: "native-#{SecureRandom.hex(8)}")
    project = create(:project, organization: organization)
    service = ActiveStorage::Blob.services.fetch(Rails.configuration.active_storage.service.to_s)
    uploaded, finish, collector_pid = Queue.new, Queue.new, Queue.new
    allow(service).to receive(:upload).and_wrap_original do |method, *args, **kwargs|
      uploaded << true
      finish.pop
      method.call(*args, **kwargs)
    end
    upload = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        Artifacts::NativeSymbols::Upload.call(project: Projects::Project.find(project.id), account: nil, metadata: metadata, object_base64: Base64.strict_encode64(bytes))
      rescue ActiveRecord::RecordNotFound
        :tenant_deleted
      end
    end
    Timeout.timeout(10) { uploaded.pop }
    blob = Artifacts::Blob.find_by!(project_id: project.id)
    project.destroy!
    collector = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        collector_pid << connection.select_value("SELECT pg_backend_pid()")
        Artifacts::PruneJob.perform_now(project_id: project.id)
      end
    end
    pid = Timeout.timeout(5) { collector_pid.pop }
    Timeout.timeout(5) do
      loop do
        waiting = ApplicationRecord.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}")
        break if waiting == "Lock"
        sleep 0.01
      end
    end
    finish << true
    expect(upload.value).to eq(:tenant_deleted)
    collector.value
    expect(Artifacts::Blob.exists?(blob.id)).to be(false)
    expect(service.exist?(blob.key)).to be(false)
  ensure
    finish << true if finish
    upload&.join
    collector&.join
    organization&.destroy!
    Artifacts::PruneJob.perform_now(project_id: project.id) if project
  end
end
