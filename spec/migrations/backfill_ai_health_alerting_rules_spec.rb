# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260902100000_backfill_ai_health_alerting_rules")

# CYRA-712 — il controllo che avvisa quando l'intelligenza artificiale tace nasce insieme alle sue
# regole, ma solo per le organizzazioni create DOPO. Su quelle già esistenti — cioè su tutte quelle
# vere — Alerting::Evaluate non troverebbe nessuna regola e butterebbe via l'evento: il controllo
# girerebbe ogni quarto d'ora per non dire niente a nessuno.
RSpec.describe BackfillAiHealthAlertingRules do
  def run_backfill
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  it "installa entrambe le regole su un'organizzazione che ne è priva" do
    org = create(:organization)
    Alerting::Rule.where(organization: org, event_type: %i[ai_unavailable ai_available]).delete_all

    run_backfill

    tipi = Alerting::Rule.where(organization: org).map(&:event_type)
    expect(tipi).to include("ai_unavailable", "ai_available")
  end

  it "la caduta nasce accesa, org-wide e con il freno a un'ora" do
    org = create(:organization)
    Alerting::Rule.where(organization: org, event_type: :ai_unavailable).delete_all

    run_backfill

    rule = Alerting::Rule.find_by(organization: org, event_type: :ai_unavailable)
    expect(rule).to be_enabled
    expect(rule.project_id).to be_nil
    expect(rule.environment_id).to be_nil
    # Stesso throttle che ricevono le organizzazioni nuove da InstallDefaults.
    expect(rule.throttle_seconds).to eq(3600)
  end

  it "è idempotente: rieseguirla non duplica" do
    org = create(:organization)

    2.times { run_backfill }

    expect(Alerting::Rule.where(organization: org, event_type: :ai_unavailable).count).to eq(1)
    expect(Alerting::Rule.where(organization: org, event_type: :ai_available).count).to eq(1)
  end

  it "non tocca una regola che l'organizzazione ha già personalizzato" do
    org = create(:organization)
    Alerting::Rule.where(organization: org, event_type: :ai_unavailable).delete_all
    esistente = create(:alerting_rule, organization: org, event_type: :ai_unavailable,
                                       name: "Come piace a me", enabled: false)

    run_backfill

    esistente.reload
    expect(esistente.name).to eq("Come piace a me")
    expect(esistente).not_to be_enabled
    expect(Alerting::Rule.where(organization: org, event_type: :ai_unavailable).count).to eq(1)
  end
end
