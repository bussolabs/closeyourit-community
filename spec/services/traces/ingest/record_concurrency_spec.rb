# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Traces::Ingest::Record, "PostgreSQL concurrency" do
  self.use_transactional_tests = false

  let!(:organization) { create(:organization) }
  let!(:project) { create(:project, organization: organization) }

  after do
    organization.destroy! if organization.persisted?
  end

  def payload(span_id = "b" * 16, name = "checkout")
    { "resourceSpans" => [ { "scopeSpans" => [ { "spans" => [ { "traceId" => "a" * 32,
      "spanId" => span_id, "name" => name, "startTimeUnixNano" => "1", "endTimeUnixNano" => "2" } ] } ] } ] }
  end

  def concurrently(*payloads)
    ready = Queue.new
    start = Queue.new
    threads = payloads.map do |item|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          described_class.call(project: Projects::Project.find(project.id), payload: item)
        end
      end
    end
    Timeout.timeout(15) do
      threads.size.times { ready.pop }
      threads.size.times { start << true }
      threads.map(&:value)
    end
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
  end

  it "deduplicates simultaneous first deliveries and rejects a later conflicting snapshot" do
    results = concurrently(payload, payload)
    expect(results.map(&:rejected)).to eq([ 0, 0 ])
    expect(project.traces.sole.retained_spans_count).to eq(1)
    expect(project.trace_spans.count).to eq(1)
    results = concurrently(payload("b" * 16, "conflict"), payload("c" * 16))
    expect(results.map(&:rejected)).to eq([ 1, 0 ])
    expect(project.traces.sole.retained_spans_count).to eq(2)
  end

  it "preserves new spans when pruning waits for the same trace lock" do
    travel_to(20.days.ago) { described_class.call(project: project, payload: payload) }
    trace = project.traces.sole
    ready = Queue.new
    thread = nil
    trace.with_lock do
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          Traces::PruneJob.perform_now
        end
      end
      Timeout.timeout(15) { ready.pop }
      described_class.call(project: project, payload: payload("c" * 16))
    end
    Timeout.timeout(15) { thread.value }
    expect(project.trace_spans.pluck(:span_id)).to eq([ "c" * 16 ])
    expect(trace.reload.retained_spans_count).to eq(1)
    expect(trace.expired_spans_count).to eq(1)
  ensure
    thread&.kill if thread&.alive?
    thread&.join
  end
end
