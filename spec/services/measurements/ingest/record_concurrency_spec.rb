# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Measurements::Ingest::Record, "PostgreSQL cardinality concurrency" do
  self.use_transactional_tests = false
  let!(:organization) { create(:organization) }
  let!(:project) { create(:project, organization: organization) }

  after { organization.destroy! if organization.persisted? }

  def payload(name)
    { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ { "name" => name,
      "gauge" => { "dataPoints" => [ { "timeUnixNano" => "1", "asInt" => "2" } ] } } ] } ] } ] }
  end

  it "serializes concurrent admissions so the last active slot cannot be spent twice" do
    stub_const("Measurements::Ingest::Record::ACTIVE_SERIES_LIMIT", 1)
    ready = Queue.new
    start = Queue.new
    threads = %w[first second].map do |name|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          described_class.call(project: Projects::Project.find(project.id), payload: payload(name))
        end
      end
    end
    results = Timeout.timeout(15) do
      2.times { ready.pop }
      2.times { start << true }
      threads.map(&:value)
    end
    expect(results.map(&:rejected).sort).to eq([ 0, 1 ])
    expect(project.measurement_series.count).to eq(1)
    expect(project.measurement_points.count).to eq(1)
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
  end
end
