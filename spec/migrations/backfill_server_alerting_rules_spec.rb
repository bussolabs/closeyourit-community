# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260806160621_backfill_server_alerting_rules")

RSpec.describe BackfillServerAlertingRules do
  let(:server_events) do
    %w[server_down server_up server_service_failed server_smart_failing server_db_down agents_stalled]
  end

  def run_backfill
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  it "installa le regole server/agenti org-wide e attive su un'org esistente senza regole" do
    org = create(:organization)

    run_backfill

    rules = Alerting::Rule.where(organization: org)
    expect(rules.map(&:event_type)).to contain_exactly(*server_events)
    expect(rules).to all(be_enabled)
    expect(rules.map(&:project_id).uniq).to eq([ nil ])
    expect(rules.map(&:environment_id).uniq).to eq([ nil ])
  end

  it "è idempotente (rieseguibile senza duplicare)" do
    org = create(:organization)

    2.times { run_backfill }

    expect(Alerting::Rule.where(organization: org).count).to eq(server_events.size)
    expect(Alerting::Rule.where(organization: org, event_type: :server_down).count).to eq(1)
  end

  it "non tocca una regola server_down org-wide già configurata a mano, anche se disabilitata" do
    org = create(:organization)
    existing = create(:alerting_rule, :server_down, :disabled, organization: org, name: "Il mio server")

    run_backfill

    downs = Alerting::Rule.where(organization: org, event_type: :server_down)
    expect(downs.count).to eq(1)
    expect(existing.reload).not_to be_enabled
    expect(existing.name).to eq("Il mio server")
  end

  it "non duplica: una regola server_down scoped già esistente conta come installata (Evaluate la valuta su tutta l'org)" do
    org = create(:organization)
    scoped = create(:alerting_rule, :server_down, :scoped, organization: org)

    run_backfill

    downs = Alerting::Rule.where(organization: org, event_type: :server_down)
    expect(downs.count).to eq(1)
    expect(downs.first).to eq(scoped)
  end

  it "copre tutte le org esistenti" do
    org_a = create(:organization)
    org_b = create(:organization)

    run_backfill

    [ org_a, org_b ].each do |org|
      expect(Alerting::Rule.where(organization: org).map(&:event_type)).to contain_exactly(*server_events)
    end
  end
end
