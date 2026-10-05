# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260810110000_backfill_agents_host_stale_alerting_rule")

RSpec.describe BackfillAgentsHostStaleAlertingRule do
  def run_backfill
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  it "installa la regola agents_host_stale org-wide e attiva su un'org esistente" do
    org = create(:organization)

    run_backfill

    rule = Alerting::Rule.find_by(organization: org, event_type: :agents_host_stale)
    expect(rule).to be_present
    expect(rule).to be_enabled
    expect(rule.project_id).to be_nil
    expect(rule.environment_id).to be_nil
    # Throttle a 1h come le org nuove (InstallDefaults): il re-alert su una macchina morta non spamma.
    expect(rule.throttle_seconds).to eq(3600)
  end

  # Un'org nata PRIMA della feature non ha la regola: il backfill è ciò che la copre.
  it "installa la regola su un'org che ne è priva (pre-feature)" do
    org = create(:organization)
    Alerting::Rule.where(organization: org, event_type: :agents_host_stale).delete_all

    run_backfill

    expect(Alerting::Rule.where(organization: org, event_type: :agents_host_stale).count).to eq(1)
  end

  it "è idempotente (rieseguibile senza duplicare)" do
    org = create(:organization)

    2.times { run_backfill }

    expect(Alerting::Rule.where(organization: org, event_type: :agents_host_stale).count).to eq(1)
  end

  it "non tocca una regola agents_host_stale già configurata a mano, anche se disabilitata" do
    org = create(:organization)
    Alerting::Rule.where(organization: org, event_type: :agents_host_stale).delete_all
    existing = create(:alerting_rule, :disabled, event_type: :agents_host_stale, organization: org, name: "La mia")

    run_backfill

    rules = Alerting::Rule.where(organization: org, event_type: :agents_host_stale)
    expect(rules.count).to eq(1)
    expect(existing.reload).not_to be_enabled
    expect(existing.name).to eq("La mia")
  end

  it "copre tutte le org esistenti" do
    org_a = create(:organization)
    org_b = create(:organization)
    [ org_a, org_b ].each { |org| Alerting::Rule.where(organization: org, event_type: :agents_host_stale).delete_all }

    run_backfill

    [ org_a, org_b ].each do |org|
      expect(Alerting::Rule.where(organization: org, event_type: :agents_host_stale).count).to eq(1)
    end
  end
end
