# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member measurement input boundaries", type: :request do
  let(:project) { create(:project) }
  let(:account) { create(:account) }
  let(:ending) { Time.current.beginning_of_minute }

  before do
    create(:membership, account: account, organization: project.organization, role: :owner)
    Types::InstallDefaults.call(organization: project.organization)
    post login_path, params: { email: account.email, password: "Secret123!" }
    points = [ true, false ].map do |enabled|
      { "timeUnixNano" => (ending.to_i * 1_000_000_000).to_s, "asInt" => "1",
        "attributes" => [ { "key" => "enabled", "value" => { "boolValue" => enabled } },
          { "key" => "ratio", "value" => { "doubleValue" => enabled ? 1.5 : 2.5 } } ] }
    end
    Measurements::Ingest::Record.call(project: project, payload: { "resourceMetrics" => [ { "scopeMetrics" => [ {
      "metrics" => [ { "name" => "requests", "gauge" => { "dataPoints" => points } } ] }
    ] } ] })
  end

  [ [ "enabled", "boolValue", "true" ], [ "enabled", "boolValue", "false" ], [ "ratio", "doubleValue", "1.5" ] ].each do |key, type, value|
    it "filters #{key} by #{type} #{value} without coercion" do
      get member_monitoring_measurements_path, params: { attribute_scope: "point", attribute_key: key, attribute_type: type, attribute_value: value }
      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).css('[data-test="measurement-row"]').size).to eq(1)
    end
  end

  [ { attribute_scope: "unknown" }, { attribute_type: "unknown" }, { attribute_value: [ "true" ] },
    { attribute_type: "doubleValue", attribute_value: "invalid" } ].each_with_index do |change, index|
    it "rejects invalid typed filter variant #{index + 1}" do
      base = { attribute_scope: "point", attribute_key: "enabled", attribute_type: "boolValue", attribute_value: "true" }
      get member_monitoring_measurements_path, params: base.merge(change)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('data-test="measurements-query-error"')
    end
  end

  it "rejects more than 200 project filters" do
    get member_monitoring_measurements_path, params: { project_id: Array.new(201) { SecureRandom.uuid } }
    expect(response).to have_http_status(:unprocessable_content)
  end

  [ { to: "" }, { from: "2026-02-30T12:00:00Z" }, { from: "2026-10-01T25:00:00Z" },
    { from: "2026-10-01T12:00:00+24:00" }, { from: [ "2026-10-01T12:00:00Z" ] },
    { from: "2026-10-02T12:00:00Z", to: "2026-10-01T12:00:00Z" } ].each_with_index do |change, index|
    it "rejects invalid custom time bounds variant #{index + 1}" do
      series = project.measurement_series.first
      base = { from: (ending - 60).iso8601, to: ending.iso8601 }
      get member_monitoring_measurement_path(series), params: base.merge(change)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('data-test="measurements-query-error"')
    end
  end

  it "rejects a statistic unsupported by the series" do
    get member_monitoring_measurement_path(project.measurement_series.first), params: { statistic: "percentile" }
    expect(response).to have_http_status(:unprocessable_content)
  end
end
