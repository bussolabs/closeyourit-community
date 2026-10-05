# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260806201537_backfill_container_down_alerting_rule")

RSpec.describe BackfillContainerDownAlertingRule do
  def run_backfill
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  it "installa la regola server_container_down org-wide e attiva su un'org esistente" do
    org = create(:organization)

    run_backfill

    rule = Alerting::Rule.find_by(organization: org, event_type: :server_container_down)
    expect(rule).to be_present
    expect(rule).to be_enabled
    expect(rule.project_id).to be_nil
    expect(rule.environment_id).to be_nil
  end

  it "è idempotente (rieseguibile senza duplicare)" do
    org = create(:organization)

    2.times { run_backfill }

    expect(Alerting::Rule.where(organization: org, event_type: :server_container_down).count).to eq(1)
  end

  it "non tocca una regola server_container_down già configurata a mano, anche se disabilitata" do
    org = create(:organization)
    existing = create(:alerting_rule, :disabled, event_type: :server_container_down,
                                      organization: org, name: "Il mio")

    run_backfill

    rules = Alerting::Rule.where(organization: org, event_type: :server_container_down)
    expect(rules.count).to eq(1)
    expect(existing.reload).not_to be_enabled
    expect(existing.name).to eq("Il mio")
  end

  it "copre tutte le org esistenti" do
    org_a = create(:organization)
    org_b = create(:organization)

    run_backfill

    [ org_a, org_b ].each do |org|
      expect(Alerting::Rule.where(organization: org, event_type: :server_container_down).count).to eq(1)
    end
  end
end
