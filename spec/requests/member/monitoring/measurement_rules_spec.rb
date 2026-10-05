# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member measurement rules", type: :request do
  let(:project) { create(:project) }
  let(:account) { create(:account) }
  let(:ending) { Time.current.beginning_of_minute - 1.minute }
  let(:series) do
    point = { "timeUnixNano" => ((ending.to_i - 1) * 1_000_000_000).to_s, "asInt" => "9" }
    Measurements::Ingest::Record.call(project: project, payload: { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ { "name" => "queue.depth", "gauge" => { "dataPoints" => [ point ] } } ] } ] } ] })
    project.measurement_series.find_by!(name: "queue.depth")
  end
  let(:attributes) do
    { name: "Queue threshold", project_id: project.id, measurement_series_id: series.id,
      statistic: "last", comparison: "gt", threshold: "5", window_seconds: "60",
      throttle_seconds: "300", enabled: "1", channel_ids: [ "" ] }
  end

  before do
    create(:membership, account: account, organization: project.organization, role: :owner)
    Types::InstallDefaults.call(organization: project.organization)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "saves a typed rule on its exact series without requiring webhooks and edits atomically" do
    get new_member_monitoring_measurement_rule_path, params: { project_id: project.id, measurement_series_id: series.id }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="measurement-rule-save"', series.id)
    expect { post member_monitoring_measurement_rules_path, params: attributes }.to change(Alerting::Rule, :count).by(1)
    rule = project.organization.alerting_rules.sole
    expect(rule.measurement_config).to include("version" => 1, "window_seconds" => 60, "threshold" => "5")
    expect(rule.channels).to be_empty
    patch member_monitoring_measurement_rule_path(rule), params: attributes.merge(name: "Do not commit", window_seconds: "60.5")
    expect(response).to have_http_status(:unprocessable_content)
    expect(rule.reload.name).to eq("Queue threshold")
    expect(response.body).to include("Do not commit")
  end

  it "keeps visible read access separate from management and rejects foreign channels and series" do
    post member_monitoring_measurement_rules_path, params: attributes
    rule = project.organization.alerting_rules.sole
    other = create(:project)
    channel = create(:alerting_channel, organization: other.organization, config: { "url" => "https://1.1.1.1/owned-test-sink" })
    expect { post member_monitoring_measurement_rules_path, params: attributes.merge(channel_ids: [ channel.id ]) }.not_to change(Alerting::Rule, :count)
    expect(response).to have_http_status(:unprocessable_content)
    account.memberships.find_by!(organization: project.organization).update!(role: :member)
    create(:project_membership, project: project, account: account)
    get member_monitoring_measurement_rule_path(rule)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('data-test="measurement-rule-edit"')
    patch member_monitoring_measurement_rule_path(rule), params: attributes.merge(threshold: "2")
    expect(response).to redirect_to(root_path)
    delete member_monitoring_measurement_rule_path(rule), params: { confirm: "1" }
    expect(response).to redirect_to(root_path)
    other_rule = create(:alerting_rule, organization: other.organization, project: other)
    get member_monitoring_measurement_rule_path(other_rule)
    expect(response).to have_http_status(:not_found)
  end

  it "shows the latest unknown observation alongside the previous known state" do
    post member_monitoring_measurement_rules_path, params: attributes
    rule = project.organization.alerting_rules.sole
    Alerting::Measurements::Evaluate.call(rule_id: rule.id, window_end: ending, at: ending + 35.seconds)
    Alerting::Measurements::Evaluate.call(rule_id: rule.id, window_end: ending + 60.seconds, at: ending + 95.seconds)
    get member_monitoring_measurement_rule_path(rule)
    expect(response).to have_http_status(:ok)
    html = Nokogiri::HTML(response.body)
    expect(html.at_css('[data-test="measurement-latest-observation"]').text).to include("Unknown", "—")
    expect(html.at_css('[data-test="measurement-last-known"]').text).to include("Firing")
    expect(response.body).to include("does not recover", "9")
  end
  it "uses each historical count snapshot's unit after the current statistic changes" do
    point = { "timeUnixNano" => (ending.to_i * 1_000_000_000).to_s, "startTimeUnixNano" => ((ending.to_i - 60) * 1_000_000_000).to_s,
      "count" => "2", "sum" => 15, "explicitBounds" => [ 5, 10 ], "bucketCounts" => [ "0", "2", "0" ] }
    Measurements::Ingest::Record.call(project: project, payload: { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ { "name" => "latency", "unit" => "ms", "histogram" => { "aggregationTemporality" => 1, "dataPoints" => [ point ] } } ] } ] } ] })
    histogram = project.measurement_series.sole
    post member_monitoring_measurement_rules_path, params: attributes.merge(measurement_series_id: histogram.id, statistic: "count")
    rule = project.organization.alerting_rules.sole
    Alerting::Measurements::Evaluate.call(rule_id: rule.id, window_end: ending, at: ending + 35.seconds)
    patch member_monitoring_measurement_rule_path(rule), params: attributes.merge(measurement_series_id: histogram.id, statistic: "sum")
    get member_monitoring_measurement_rule_path(rule)
    expect(response).to have_http_status(:ok)
    html = Nokogiri::HTML(response.body)
    expect(html.at_css('[data-test="measurement-latest-observation"]').text).to include("2 observations", "Previous configuration")
    expect(html.at_css('[data-test="measurement-evaluation"]').text).to include("2 observations")
    expect(html.at_css('[data-test="measurement-evaluation"]').text).not_to include("2 ms")
  end

  it "routes legacy measurement forms to the dedicated surface and requires deletion confirmation" do
    post member_monitoring_measurement_rules_path, params: attributes
    rule = project.organization.alerting_rules.sole
    get member_alerting_rule_path(rule)
    expect(response).to redirect_to(member_monitoring_measurement_rule_path(rule))
    get edit_member_alerting_rule_path(rule)
    expect(response).to redirect_to(edit_member_monitoring_measurement_rule_path(rule))
    expect { delete member_monitoring_measurement_rule_path(rule) }.not_to change(Alerting::Rule, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect { delete member_monitoring_measurement_rule_path(rule), params: { confirm: "1" } }.to change(Alerting::Rule, :count).by(-1)
  end

  it "cannot save before loading an accessible exact series" do
    get new_member_monitoring_measurement_rule_path
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css('[data-test="measurement-rule-save"][disabled]')).to be_present
    expect { post member_monitoring_measurement_rules_path, params: attributes.merge(measurement_series_id: SecureRandom.uuid) }.not_to change(Alerting::Rule, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "denies hidden measurement rules on legacy member, mute and CLI routes" do
    post member_monitoring_measurement_rules_path, params: attributes
    rule = project.organization.alerting_rules.sole
    account.memberships.find_by!(organization: project.organization).update!(role: :member)
    create(:account_permission, account: account, organization: project.organization, permission_key: "alerts.manage")
    token = Accounts::ApiTokens::Issue.call(account: account, organization: project.organization, name: "Restricted manager").value[:secret]
    headers = { "Authorization" => "Bearer #{token}" }
    [ [ :get, member_alerting_rule_path(rule) ], [ :delete, member_alerting_rule_path(rule) ],
     [ :patch, "/member/alerting_rules/#{rule.id}/mute" ], [ :delete, "/member/alerting_rules/#{rule.id}/mute" ] ].each do |verb, path|
      Prosopite.finish
      Prosopite.scan
      public_send(verb, path)
      expect(response).to have_http_status(:not_found)
    end
    get member_alerting_rules_path
    expect(response.body).not_to include("Queue threshold")
    get "/cli/v1/alert_rules", headers: headers
    expect(response.parsed_body.fetch("data")).to be_empty
    delete "/cli/v1/alert_rules/#{rule.id}", headers: headers
    expect(response).to have_http_status(:not_found)
    expect(rule.reload.enabled).to be(true)
  end

  it "keeps deleted legacy notifications in totals without exposing deleted private measurement notifications" do
    post member_monitoring_measurement_rules_path, params: attributes
    measurement = project.organization.alerting_rules.sole
    legacy = create(:alerting_rule, organization: project.organization)
    create(:alerting_notification, organization: project.organization, rule: legacy)
    create(:alerting_notification, organization: project.organization, rule: measurement, project: project, event_type: :measurement_threshold)
    legacy.destroy!
    measurement.destroy!
    account.memberships.find_by!(organization: project.organization).update!(role: :member)
    create(:account_permission, account: account, organization: project.organization, permission_key: "alerts.manage")
    get member_alerting_rules_path
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css('[data-test="alerting-stat-triggered"]').text).to include("1")
    expect(Nokogiri::HTML(response.body).at_css('[data-test="alerting-stat-triggered"]').text.strip).to start_with("1 ")
  end
end
