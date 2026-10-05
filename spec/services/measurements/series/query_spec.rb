# frozen_string_literal: true

require "rails_helper"

RSpec.describe Measurements::Series::Query do
  let(:project) { create(:project) }

  def series(resource, attributes = [], project: self.project)
    Measurements::Ingest::Record.call(project: project, payload: { "resourceMetrics" => [ {
      "resource" => { "attributes" => resource }, "scopeMetrics" => [ { "metrics" => [ {
        "name" => "reading", "gauge" => { "dataPoints" => [ { "timeUnixNano" => "1000000000", "asInt" => "1", "attributes" => attributes } ] }
      } ] } ] } ] })
    project.measurement_series.where("point_attributes = ?::jsonb", attributes.to_json).sole
  end

  def attr(key, value) = { "key" => key, "value" => value }
  def query(filters) = described_class.call(scope: project.measurement_series, filters: filters).pluck(:id)

  it "preserves typed values, project isolation and canonical environment precedence" do
    integer = series([ attr("service.name", "stringValue" => "checkout"), attr("deployment.environment", "stringValue" => "old"), attr("deployment.environment.name", "stringValue" => "production") ], [ attr("replica", "intValue" => "1") ])
    string = series([ attr("deployment.environment", "stringValue" => "old") ], [ attr("replica", "stringValue" => "1") ])
    series([], [], project: create(:project))
    expect(query("point_attributes" => [ attr("replica", "intValue" => "1") ])).to eq([ integer.id ])
    expect(query("environment" => "old")).to eq([ string.id ])
    expect(query("service_name" => "checkout", "environment" => "production")).to eq([ integer.id ])
    expect(query({})).to contain_exactly(integer.id, string.id)
    expect(query("name" => "absent")).to be_empty
  end

  it "rejects unknown operators, oversized filters and invalid scalar types" do
    expect { query("resource_attributes" => [ attr("x", "arrayValue" => {}) ]) }.to raise_error(described_class::Invalid)
    expect { query("resource_attributes" => [ attr("x", "intValue" => 1) ]) }.to raise_error(described_class::Invalid)
    expect { query("resource_attributes" => Array.new(17) { attr("x", "boolValue" => true) }) }.to raise_error(described_class::Invalid)
    expect { query("unexpected" => "x") }.to raise_error(described_class::Invalid)
    expect { query("name" => "x" * 17000) }.to raise_error(described_class::Invalid)
  end
end
