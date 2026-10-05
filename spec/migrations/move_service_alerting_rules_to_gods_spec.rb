# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260928120000_move_service_alerting_rules_to_gods")

# CYRA-875 — the internal service alerts leave the customer organizations and stay only with the gods.
RSpec.describe MoveServiceAlertingRulesToGods do
  let(:service_events) { %i[embedding_down ai_unavailable ai_available cache_unavailable] }

  def run_migration
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  it "removes the service rules from a customer organization and keeps its other rules" do
    customer = create(:organization)
    service_events.each { |event| create(:alerting_rule, organization: customer, event_type: event) }
    uptime = create(:alerting_rule, organization: customer, event_type: :uptime_down)

    run_migration

    expect(Alerting::Rule.where(organization: customer, event_type: service_events)).to be_empty
    expect(uptime.reload).to be_present
  end

  it "keeps past notifications, detached from the deleted rule" do
    customer = create(:organization)
    rule = create(:alerting_rule, organization: customer, event_type: :ai_available)
    notification = create(:alerting_notification, organization: customer, rule: rule, event_type: :ai_available)

    run_migration

    expect(notification.reload.rule_id).to be_nil
  end

  it "keeps the service rules of each god's home organization" do
    home = create(:organization)
    other = create(:organization)
    god = create(:account, god: true)
    create(:membership, account: god, organization: home, created_at: 2.days.ago)
    create(:membership, account: god, organization: other, created_at: 1.day.ago)
    [ home, other ].each { |org| create(:alerting_rule, organization: org, event_type: :ai_unavailable) }

    run_migration

    expect(Alerting::Rule.where(organization: home, event_type: :ai_unavailable).count).to eq(1)
    expect(Alerting::Rule.where(organization: other, event_type: :ai_unavailable)).to be_empty
  end

  it "leaves a rule the god already customized untouched" do
    home = create(:organization)
    create(:membership, account: create(:account, god: true), organization: home)
    own = create(:alerting_rule, organization: home, event_type: :cache_unavailable, name: "Mine", enabled: false)

    run_migration

    expect(own.reload.name).to eq("Mine")
    expect(Alerting::Rule.where(organization: home, event_type: :cache_unavailable).count).to eq(1)
  end
end
