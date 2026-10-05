# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260904120000_backfill_ingest_rejected_alerting_rule")

# CYRA-775 — l'avviso che spiega perché una macchina non è stata dichiarata giù nasce insieme alle
# regole di default, ma solo per le organizzazioni create DOPO. Su quelle già esistenti — cioè su
# tutte quelle vere — Alerting::Evaluate non troverebbe nessuna regola e butterebbe via l'evento: le
# macchine smetterebbero di risultare cadute senza che nessuno sappia il perché.
RSpec.describe BackfillIngestRejectedAlertingRule do
  def run_backfill
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  it "installa la regola su un'organizzazione che ne è priva" do
    org = create(:organization)
    Alerting::Rule.where(organization: org, event_type: :server_ingest_rejected).delete_all

    run_backfill

    expect(Alerting::Rule.where(organization: org).map(&:event_type)).to include("server_ingest_rejected")
  end

  it "nasce accesa, org-wide e con il freno a un'ora" do
    org = create(:organization)
    Alerting::Rule.where(organization: org, event_type: :server_ingest_rejected).delete_all

    run_backfill

    rule = Alerting::Rule.find_by(organization: org, event_type: :server_ingest_rejected)
    expect(rule).to be_enabled
    expect(rule.project_id).to be_nil
    expect(rule.environment_id).to be_nil
    # Stesso freno che ricevono le organizzazioni nuove da InstallDefaults.
    expect(rule.throttle_seconds).to eq(3600)
  end

  it "è idempotente: rieseguirla non duplica" do
    org = create(:organization)

    2.times { run_backfill }

    expect(Alerting::Rule.where(organization: org, event_type: :server_ingest_rejected).count).to eq(1)
  end

  it "non tocca una regola che l'organizzazione ha già personalizzato" do
    org = create(:organization)
    Alerting::Rule.where(organization: org, event_type: :server_ingest_rejected).delete_all
    esistente = create(:alerting_rule, organization: org, event_type: :server_ingest_rejected,
                                       name: "Come piace a me", enabled: false)

    run_backfill

    esistente.reload
    expect(esistente.name).to eq("Come piace a me")
    expect(esistente).not_to be_enabled
    expect(Alerting::Rule.where(organization: org, event_type: :server_ingest_rejected).count).to eq(1)
  end
end
