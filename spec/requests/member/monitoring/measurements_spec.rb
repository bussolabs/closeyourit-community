# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member measurements", type: :request do
  let(:project) { create(:project) }
  let(:account) { create(:account) }
  let(:ending) { Time.current.beginning_of_minute }

  before do
    create(:membership, account: account, organization: project.organization, role: :owner)
    Types::InstallDefaults.call(organization: project.organization)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def ingest(target: project, name: "requests", value: 0, kind: "gauge", attributes: [], unit: "{request}")
    point = { "timeUnixNano" => (ending.to_i * 1_000_000_000).to_s, "startTimeUnixNano" => ((ending.to_i - 60) * 1_000_000_000).to_s, "asInt" => value.to_s, "attributes" => attributes }
    metric = { "name" => name, "unit" => unit, kind => { "dataPoints" => [ point ] } }
    metric[kind].merge!("aggregationTemporality" => 1, "isMonotonic" => true) if kind == "sum"
    Measurements::Ingest::Record.call(project: target, payload: { "resourceMetrics" => [ { "resource" => { "attributes" => [ { "key" => "service.name", "value" => { "stringValue" => "checkout" } } ] }, "scopeMetrics" => [ { "metrics" => [ metric ] } ] } ] })
    target.measurement_series.find_by!(name: name)
  end

  def html = Nokogiri::HTML(response.body)

  it "distinguishes empty, filtered-empty and known zero with localized controls" do
    get "/member/monitoring/measurements"
    expect(response).to have_http_status(:ok)
    expect(html.at_css('[data-test="measurements-empty"]')).to be_present
    ingest
    get "/member/monitoring/measurements"
    expect(html.at_css('[data-test="measurement-row"]').text).to include("requests", "0", "{request}")
    expect(html.at_css('[data-test="member-nav-measurements"]')).to be_present
    get "/member/monitoring/measurements", params: { q: "missing" }
    expect(html.at_css('[data-test="measurements-no-match"]')).to be_present
    expect(html.at_css('[data-test="measurements-reset"]')).to be_present
    account.update!(locale: "it")
    get "/member/monitoring/measurements", params: { ft: "1" }
    follow_redirect! if response.redirect?
    expect(html.at_css("h1").text).to eq("Misure")
  end

  it "applies visible project scope before typed filtering and rejects invisible details" do
    visible = ingest(attributes: [ { "key" => "attempt", "value" => { "intValue" => "1" } } ])
    hidden = create(:project, organization: project.organization, name: "Hidden telemetry")
    private_series = ingest(target: hidden, name: "hidden-name")
    account.memberships.find_by!(organization: project.organization).update!(role: :member)
    create(:project_membership, project: project, account: account)
    get "/member/monitoring/measurements", params: { attribute_scope: "point", attribute_key: "attempt", attribute_type: "intValue", attribute_value: "1" }
    expect(html.css('[data-test="measurement-row"]').size).to eq(1)
    expect(response.body).not_to include("hidden-name", "Hidden telemetry")
    expect(html.at_css('[data-test="measurement-new-alert"]')).to be_nil
    get "/member/monitoring/measurements/#{private_series.id}"
    expect(response).to have_http_status(:not_found)
    get "/member/monitoring/measurements/#{visible.id}", params: { from: (ending - 60).iso8601, to: ending.iso8601 }
    expect(response).to have_http_status(:ok)
  end

  it "shows unknown buckets separately from zero and keeps rate units explicit" do
    series = ingest(kind: "sum", value: 120)
    get "/member/monitoring/measurements/#{series.id}", params: { from: (ending - 60).iso8601, to: ending.iso8601, statistic: "rate", interval_seconds: "60" }
    expect(response).to have_http_status(:ok)
    expect(html.at_css('[data-test="measurement-bucket"]').text).to include("2", "{request}/s")
    get "/member/monitoring/measurements/#{series.id}", params: { from: ending.iso8601, to: (ending + 60).iso8601, statistic: "rate" }
    expect(html.at_css('[data-test="measurement-bucket"]').text).to include("Unknown", "—")
    expect(html.at_css('[data-test="measurement-bucket"]').text).not_to include("0 {request}/s")
  end

  it "renders a bounded query error with a retry action for invalid typed input" do
    ingest
    get "/member/monitoring/measurements", params: { attribute_scope: "point", attribute_key: "attempt", attribute_type: "boolValue", attribute_value: "maybe" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(html.at_css('[data-test="measurements-query-error"]')).to be_present
    expect(html.at_css('[data-test="measurements-retry"]')).to be_present
  end
  it "preserves percentile bounds and flags unbounded estimates as unknown" do
    point = { "timeUnixNano" => (ending.to_i * 1_000_000_000).to_s, "startTimeUnixNano" => ((ending.to_i - 60) * 1_000_000_000).to_s,
      "count" => "2", "sum" => 15, "explicitBounds" => [ 5, 10 ], "bucketCounts" => [ "0", "2", "0" ] }
    Measurements::Ingest::Record.call(project: project, payload: { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ { "name" => "latency", "unit" => "ms", "histogram" => { "aggregationTemporality" => 1, "dataPoints" => [ point ] } } ] } ] } ] })
    series = project.measurement_series.sole
    get member_monitoring_measurement_path(series), params: { from: (ending - 60).iso8601, to: ending.iso8601, statistic: "percentile", quantile: "0.5", interval_seconds: "60" }
    expect(response).to have_http_status(:ok)
    expect(html.at_css('[data-test="measurement-bucket"]').text).to include("7.5", "(5, 10]", "ms")
    expect(response.body).to include("linear_bucket_v1", "uniform distribution")
    expect(html.css('[data-test="measurement-chart"] [data-unsampled="true"]')).to be_empty
  end

  it "rejects normalized calendar dates, reversed bounds and query budgets without replacing them" do
    series = ingest
    [ { from: "2026-10-04T10:00:00+99:99", to: "2026-10-04T11:00:00Z" },
      { from: "2026-10-04T10:00:00+01:99", to: "2026-10-04T11:00:00Z" },
      { from: "2026-02-31T12:00:00Z", to: "2026-03-05T12:00:00Z" },
      { from: ending.iso8601, to: (ending - 60).iso8601 },
      { from: (ending - 2.days).iso8601, to: ending.iso8601, interval_seconds: "1" } ].each do |bounds|
      # Each HTTP request has its own N+1 scan; repeated authentication is not a query loop.
      Prosopite.finish
      Prosopite.scan
      get member_monitoring_measurement_path(series), params: bounds
      expect(response).to have_http_status(:unprocessable_content)
      expect(html.at_css('[data-test="measurements-query-error"]')).to be_present
    end
  end

  it "paginates sorted results without dropping typed predicates and resets saved filters" do
    # Independent ingestion calls create fixtures; the HTTP read remains scanned.
    allow_n_plus_one do
      14.times { |i| ingest(name: "counter-%02d" % i, attributes: [ { "key" => "dimension", "value" => { "stringValue" => " exact " } } ]) }
    end
    filters = { attribute_scope: "point", attribute_key: "dimension", attribute_type: "stringValue", attribute_value: " exact ", sort: "name" }
    get member_monitoring_measurements_path, params: filters.merge(page: "2")
    expect(response).to have_http_status(:ok)
    expect(html.css('[data-test="measurement-row"]').size).to eq(2)
    expect(html.at_css('[data-test="measurement-row"]').text).to include("counter-12")
    post member_saved_views_path, params: filters.merge(resource_type: "measurement_series", name: "Exact spacing")
    expect(response).to be_redirect
    expect(SavedView.last.filters["attribute_value"]).to eq(" exact ")
    follow_redirect!
    expect(html.css('[data-test="measurement-row"]').size).to eq(12)
    expect(html.at_css('input[name="attribute_value"]').attr("value")).to eq(" exact ")
    get member_monitoring_measurements_path, params: { ft: "1", q: "missing" }
    expect(html.at_css('[data-test="measurements-no-match"]')).to be_present
    get html.at_css('[data-test="measurements-reset"]').attr("href")
    expect(html.css('[data-test="measurement-row"]').size).to eq(12)
  end

  it "preserves exact semantic keys and whitespace-only values in saved and remembered filters" do
    ingest(attributes: [ { "key" => " ", "value" => { "stringValue" => "   " } } ])
    filters = { attribute_scope: "point", attribute_key: " ", attribute_type: "stringValue", attribute_value: "   " }
    get member_monitoring_measurements_path, params: filters
    expect(html.css('[data-test="measurement-row"]').size).to eq(1)
    expect(html.at_css('[data-test="filter-chip-attribute_key"]')["hidden"]).to be_nil
    get member_monitoring_measurements_path
    expect(response).to be_redirect
    expect(Rack::Utils.parse_query(URI(response.location).query)).to include(filters.stringify_keys)
    follow_redirect!
    expect(html.css('[data-test="measurement-row"]').size).to eq(1)
    post member_saved_views_path, params: filters.merge(resource_type: "measurement_series", name: "Exact semantic strings", service_name: " checkout ")
    expect(response).to be_redirect
    expect(SavedView.last.filters).to include(filters.stringify_keys.merge("service_name" => " checkout "))
    follow_redirect!
    expect(html.at_css('input[name="attribute_key"]')["value"]).to eq(" ")
    expect(html.at_css('input[name="attribute_value"]')["value"]).to eq("   ")
    expect(html.at_css('input[name="service_name"]')["value"]).to eq(" checkout ")
  end
end
