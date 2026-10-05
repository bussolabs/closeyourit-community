# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe SessionHealth::Ingest::Record, "PostgreSQL session update concurrency" do
  self.use_transactional_tests = false
  let!(:organization) { create(:organization) }
  let!(:project) { create(:project, organization: organization) }
  after { organization.destroy! if organization.persisted? }

  it "serializes competing initial and terminal deliveries into one terminal session" do
    sid = SecureRandom.uuid
    states = [ { "status" => "ok", "timestamp" => "2026-10-04T01:00:00Z" }, { "status" => "crashed", "timestamp" => "2026-10-04T01:01:00Z" } ]
    ready = Queue.new
    start = Queue.new
    threads = states.map do |state|
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          payload = state.merge("sid" => sid, "init" => true, "started" => "2026-10-04T01:00:00Z", "attrs" => { "release" => "concurrent" })
          items = SessionHealth::Ingest::Decode.call(type: "session", payload: payload).map { |value| { type: "session", value: value } }
          ready << true
          start.pop
          described_class.call(project: Projects::Project.find(project.id), items: items)
        end
      end
    end
    results = Timeout.timeout(15) do
      2.times { ready.pop }
      2.times { start << true }
      threads.map(&:value)
    end
    expect(results.sum(&:rejected)).to eq(0)
    expect(project.health_sessions.sole).to have_attributes(status: "crashed", errors_count: 1)
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
  end
end
