# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Logs::Otlp::Record, "PostgreSQL identity concurrency" do
  self.use_transactional_tests = false
  let!(:organization) { create(:organization) }
  let!(:project) { create(:project, organization: organization) }

  after { organization.destroy! if organization.persisted? }

  def payload(body = "same record")
    { "resourceLogs" => [ { "scopeLogs" => [ { "logRecords" => [ { "body" => { "stringValue" => body },
      "attributes" => [ { "key" => "log.record.uid", "value" => { "stringValue" => "concurrent-record" } } ] } ] } ] } ] }
  end

  it "serializes simultaneous first arrivals and counts a conflicting duplicate without losing a new record" do
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          described_class.call(project: Projects::Project.find(project.id), payload: payload)
        end
      end
    end
    results = Timeout.timeout(15) do
      2.times { ready.pop }
      2.times { start << true }
      threads.map(&:value)
    end
    expect(results.map(&:rejected)).to eq([ 0, 0 ])
    expect(project.logs_entries.count).to eq(1)
    expect(described_class.call(project: project, payload: payload("conflict")).rejected).to eq(1)
    expect(project.logs_entries.sole.message).to eq("same record")
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
  end
end
