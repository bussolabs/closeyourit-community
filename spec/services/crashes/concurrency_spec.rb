# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Crash admission concurrency", :real_concurrency do
  self.use_transactional_tests = false

  it "reserves the last available quota atomically across independent database connections" do
    organization = create(:organization, slug: "crashes-#{SecureRandom.hex(8)}")
    project = create(:project, organization: organization)
    10.times.map do |index|
      Crashes::Blob.create!(project_id: project.id, key: SecureRandom.hex, service_name: "test", byte_size: Crashes::MAX_FILE - (index.zero? ? 3 : 0), sha256: "a" * 64, reserved_until: 1.hour.from_now)
    end
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map do |index|
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ready << true
          start.pop
          Crashes::Record.call(project: Projects::Project.find(project.id), event: { "event_id" => (index + 1).to_s * 32 }, items: [ { header: { "filename" => "test.txt" }, bytes: "abc" } ])
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    results = threads.map(&:value)
    expect(results.sum(&:accepted)).to eq(1)
    expect(results.sum(&:rejected)).to eq(1)
    expect(Crashes::Blob.where(project_id: project.id).sum(:byte_size)).to eq(Crashes::MAX_PROJECT_BYTES)
  ensure
    project&.destroy!
    Crashes::PruneJob.perform_now if project
    organization&.destroy!
  end

  it "keeps the lifecycle row until an upload racing tenant deletion has finished" do
    organization = create(:organization, slug: "crashes-#{SecureRandom.hex(8)}")
    project = create(:project, organization: organization)
    started, finish = Queue.new, Queue.new
    service = ActiveStorage::Blob.services.fetch("test")
    uploaded_key = nil
    allow(service).to receive(:upload).and_wrap_original do |original, key, io, **options|
      uploaded_key = key
      started << true
      finish.pop
      original.call(key, io, **options)
    end
    upload = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        Crashes::Record.call(project: Projects::Project.find(project.id), event: { "event_id" => "e" * 32 }, items: [ { header: {}, bytes: "hello" } ])
      rescue ActiveRecord::RecordNotFound
        :project_deleted
      end
    end
    started.pop
    project.destroy!
    pruning = Queue.new
    prune = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        pruning << ApplicationRecord.connection.select_value("SELECT pg_backend_pid()")
        Crashes::PruneJob.perform_now
      end
    end
    pruning_pid = pruning.pop.to_i
    Timeout.timeout(5) do
      loop do
        break if ApplicationRecord.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{pruning_pid}") == "Lock"
        sleep 0.01
      end
    end
    expect(Crashes::Blob.where(project_id: project.id).count).to eq(1)
    finish << true
    expect(upload.value).to eq(:project_deleted)
    prune.value
    expect(Crashes::Blob.where(project_id: project.id)).to be_empty
    expect(service.exist?(uploaded_key)).to be(false)
  ensure
    finish << true if finish && upload&.alive?
    upload&.join
    prune&.join
    project&.destroy! if project&.persisted?
    organization&.destroy!
  end

  it "rechecks current metadata if a report is deleted and recreated during upload" do
    organization = create(:organization, slug: "crashes-#{SecureRandom.hex(8)}")
    project = create(:project, organization: organization)
    event = { "event_id" => "f" * 32, "release" => "v1" }
    original = Crashes::Record.call(project: project, event: event, items: [ { header: { "filename" => "first.txt" }, bytes: "first" } ]).report
    started, finish = Queue.new, Queue.new
    service = ActiveStorage::Blob.services.fetch("test")
    allow(service).to receive(:upload).and_wrap_original do |method, key, io, **options|
      if io.string == "slow"
        started << true
        finish.pop
      end
      method.call(key, io, **options)
    end
    upload = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        Crashes::Record.call(project: Projects::Project.find(project.id), event: event, items: [ { header: { "filename" => "slow.txt" }, bytes: "slow" } ])
      end
    end
    started.pop
    project.with_lock { original.destroy! }
    replacement = Crashes::Record.call(project: project, event: event.merge("release" => "v2"), items: [ { header: { "filename" => "replacement.txt" }, bytes: "new" } ]).report
    finish << true
    expect(upload.value.diagnostics).to eq("event_metadata_conflict" => 1)
    expect(replacement.attachments.pluck(:filename)).to eq([ "replacement.txt" ])
  ensure
    finish << true if finish && upload&.alive?
    upload&.join
    organization&.destroy!
    Crashes::PruneJob.perform_now if organization
  end
end
