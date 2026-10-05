# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Measurement rule configuration" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:actor) { create(:account).tap { |account| create(:membership, organization: organization, account: account, role: :owner) } }
  let(:series) do
    Measurements::Ingest::Record.call(project: project, payload: { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ {
      "name" => "load", "gauge" => { "dataPoints" => [ { "timeUnixNano" => "1000000000", "asInt" => "0" } ] }
    } ] } ] } ] })
    project.measurement_series.sole
  end
  let(:config) { { "version" => 1, "statistic" => "last", "comparison" => "gte", "threshold" => "0", "window_seconds" => 60 } }
  let(:attributes) { { name: "Load", event_type: "measurement_threshold", throttle_seconds: 60, project_id: project.id, measurement_series_id: series.id, measurement_config: config } }

  def save(rule, attrs)
    Alerting::Rules::Save.call(rule: rule, organization: organization, actor: actor, attributes: attrs)
  end

  it "saves exact series configuration and preserves omitted fields on partial updates" do
    rule = organization.alerting_rules.new
    expect(save(rule, attributes)).to be_ok
    expect(save(rule, { name: "New name" })).to be_ok
    expect(rule.reload.measurement_config).to eq(config)
    expect(rule.project_id).to eq(project.id)
  end

  it "rejects inaccessible series and leaves scope and channels unchanged after invalid updates" do
    rule = organization.alerting_rules.new
    channel = create(:alerting_channel, organization: organization, config: { "url" => "https://1.1.1.1/alerts" })
    expect(save(rule, attributes.merge(channel_ids: [ channel.id ]))).to be_ok
    snapshot = rule.attributes
    expect(save(rule, { name: "", channel_ids: [] })).to be_err
    expect(rule.reload.attributes).to eq(snapshot)
    expect(rule.channel_ids).to eq([ channel.id ])
    expect(save(rule, { project_id: create(:project).id })).to be_err
    expect(save(rule, { channel_ids: [ create(:alerting_channel, config: { "url" => "https://1.1.1.1/alerts" }).id ] })).to be_err
    expect(rule.reload.project_id).to eq(project.id)
    outsider = create(:account)
    expect(Alerting::Rules::Save.call(rule: organization.alerting_rules.new, organization: organization, actor: outsider, attributes: attributes)).to be_err
  end

  it "nullifies only a removed series and cannot widen the rule to organization scope" do
    rule = save(organization.alerting_rules.new, attributes).value
    series.destroy!
    expect(rule.reload.measurement_series_id).to be_nil
    expect(rule.project_id).to eq(project.id)
    expect(save(rule, { enabled: false })).to be_ok
    expect(save(rule, { project_id: nil })).to be_err
  end
  it "cannot convert an inaccessible measurement rule into a legacy rule" do
    rule = save(organization.alerting_rules.new, attributes).value
    actor.memberships.find_by!(organization: organization).update!(role: :member)
    expect(save(rule, { event_type: "error_new", project_id: nil })).to be_err
    expect(rule.reload.event_type).to eq("measurement_threshold")
    expect(rule.project_id).to eq(project.id)
  end
end
