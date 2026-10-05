# frozen_string_literal: true

require "rails_helper"

RSpec.describe Measurements::Ingest::Record do
  let(:project) { create(:project) }
  def payload(name: "requests", value: "10", start: "1", finish: "2", description: "")
    { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ { "name" => name, "description" => description,
      "sum" => { "aggregationTemporality" => 1, "isMonotonic" => true, "dataPoints" => [
        { "startTimeUnixNano" => start, "timeUnixNano" => finish, "asInt" => value }
      ] } } ] } ] } ] }
  end

  it "deduplicates retries without refreshing arrival and rejects conflicting values" do
    described_class.call(project: project, payload: payload)
    first = project.measurement_points.sole.first_received_at
    active = project.measurement_series.sole.last_admitted_at
    travel 1.day do
      expect(described_class.call(project: project, payload: payload(description: "Changed documentation")).rejected).to eq(0)
      expect(described_class.call(project: project, payload: payload(value: "11")).rejected).to eq(1)
    end
    expect(project.measurement_points.sole.first_received_at).to eq(first)
    expect(project.measurement_series.sole.last_admitted_at).to eq(active)
    expect(project.measurement_points.sole.payload["asInt"]).to eq("10")
  end

  it "rejects only new active series at the cap and permits existing active series" do
    stub_const("Measurements::Ingest::Record::ACTIVE_SERIES_LIMIT", 2)
    described_class.call(project: project, payload: payload(name: "one"))
    described_class.call(project: project, payload: payload(name: "two"))
    expect(described_class.call(project: project, payload: payload(name: "three")).rejected).to eq(1)
    expect(described_class.call(project: project, payload: payload(name: "one", start: "2", finish: "3")).rejected).to eq(0)
    expect(project.measurement_series.count).to eq(2)
    travel 25.hours do
      expect(described_class.call(project: project, payload: payload(name: "three")).rejected).to eq(0)
    end
    expect(project.measurement_series.count).to eq(3)
  end

  it "counts every rejected occurrence when an unadmitted point is repeated in one export" do
    stub_const("Measurements::Ingest::Record::ACTIVE_SERIES_LIMIT", 1)
    described_class.call(project: project, payload: payload)
    other = payload(name: "over-limit")
    points = other["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]["sum"]["dataPoints"]
    points.concat([ points.first.deep_dup, points.first.deep_dup ])
    expect(described_class.call(project: project, payload: other).rejected).to eq(3)
  end

  it "does not reactivate expired series for duplicate delivery and rejects reactivation when the cap is full" do
    stub_const("Measurements::Ingest::Record::ACTIVE_SERIES_LIMIT", 1)
    travel_to(25.hours.ago) { described_class.call(project: project, payload: payload(name: "old")) }
    described_class.call(project: project, payload: payload(name: "active"))
    expect(described_class.call(project: project, payload: payload(name: "old")).rejected).to eq(0)
    expect(described_class.call(project: project, payload: payload(name: "old", start: "2", finish: "3")).rejected).to eq(1)
    expect(project.measurement_points.count).to eq(2)
  end

  it "admits the maximum export using a bounded number of database statements" do
    described_class.call(project: project, payload: payload(name: "warm-up"))
    export = payload
    metrics = 1000.times.map { |index| payload(name: "batch.#{index}")["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0] }
    export["resourceMetrics"][0]["scopeMetrics"][0]["metrics"] = metrics
    statements = []
    subscriber = ->(_name, _start, _finish, _id, data) { statements << data[:sql] if data[:sql].include?('"measurements_') }
    result = nil
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      result = described_class.call(project: project, payload: export)
    end
    expect(result.rejected).to eq(0)
    expect(project.measurement_points.count).to eq(1001)
    expect(statements.size).to be <= 12
  end
end
