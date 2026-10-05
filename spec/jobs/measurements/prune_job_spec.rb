# frozen_string_literal: true

require "rails_helper"

RSpec.describe Measurements::PruneJob do
  let(:project) { create(:project) }
  let(:payload) { { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ { "name" => "gauge", "gauge" => { "dataPoints" => [ { "timeUnixNano" => "1", "asInt" => "2" } ] } } ] } ] } ] } }

  it "expires raw points by immutable arrival and removes only empty series" do
    travel_to(20.days.ago) { Measurements::Ingest::Record.call(project: project, payload: payload) }
    Measurements::Ingest::Record.call(project: project, payload: payload)
    described_class.perform_now
    expect(project.measurement_points.count).to eq(0)
    expect(project.measurement_series.count).to eq(0)
  end
end
