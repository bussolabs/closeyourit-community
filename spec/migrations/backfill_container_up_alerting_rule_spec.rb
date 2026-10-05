# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260828090000_backfill_container_up_alerting_rule")

# CYRA-514 — l'avviso di rientro dei contenitori esisteva dal 12 agosto, ma sulle organizzazioni
# già esistenti non aveva regola: sul feed la caduta restava l'ultima parola anche a guasto chiuso.
RSpec.describe BackfillContainerUpAlertingRule do
  def run_backfill
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  it "installa la regola su un'organizzazione che ne è priva" do
    org = create(:organization)
    Alerting::Rule.where(organization: org, event_type: :server_container_up).delete_all

    run_backfill

    rule = Alerting::Rule.find_by(organization: org, event_type: :server_container_up)
    expect(rule).to be_present
    expect(rule).to be_enabled
    expect(rule.project_id).to be_nil
    expect(rule.environment_id).to be_nil
    # Stesso throttle che ricevono le organizzazioni nuove da InstallDefaults (default del model).
    expect(rule.throttle_seconds).to eq(300)
  end

  it "è idempotente: rieseguirla non duplica" do
    org = create(:organization)

    2.times { run_backfill }

    expect(Alerting::Rule.where(organization: org, event_type: :server_container_up).count).to eq(1)
  end

  it "non tocca una regola che l'organizzazione ha già personalizzato" do
    org = create(:organization)
    Alerting::Rule.where(organization: org, event_type: :server_container_up).delete_all
    esistente = create(:alerting_rule, organization: org, event_type: :server_container_up,
                                       name: "Come piace a me", enabled: false)

    run_backfill

    esistente.reload
    expect(esistente.name).to eq("Come piace a me")
    expect(esistente).not_to be_enabled
    expect(Alerting::Rule.where(organization: org, event_type: :server_container_up).count).to eq(1)
  end
end
