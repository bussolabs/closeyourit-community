# frozen_string_literal: true

class BackfillAgentsHostStaleAlertingRule < ActiveRecord::Migration[8.1]
  # CYRA-450: agents_host_stale (intero 31) è un evento org-scoped SENZA soglia nato DOPO i backfill
  # precedenti. Le regole di alerting nascono solo su richiesta (Alerting::Rules::InstallDefaults, chiamato
  # dal provisioning), quindi NESSUNA org esistente avrebbe una regola per questo evento: il detector
  # accoderebbe l'allarme e Alerting::Evaluate, non trovando regole, non avviserebbe NESSUNO. Installa la
  # regola di default (org-wide, attiva) sulle org che non ce l'hanno già; le org nuove la ricevono dal
  # provisioning. Idempotente. event_type resta l'intero grezzo così la migrazione è autoconsistente se
  # l'enum evolve. Gemello di BackfillAgentsHostFailingAlertingRule (CYRA-282).
  EVENT_TYPE = 31
  NAME = "Agent host stale"

  class Organization < ActiveRecord::Base
    self.table_name = "organizations"
  end

  class Rule < ActiveRecord::Base
    self.table_name = "alerting_rules"
  end

  def up
    Rule.reset_column_information
    now = Time.current

    # Eventi ORG-SCOPED (agents_*): Alerting::Evaluate li valuta ignorando project/environment, quindi
    # QUALSIASI regola per quell'evento copre già tutta l'org → conta come installata e blocca il doppione.
    already = Rule.where(event_type: EVENT_TYPE).distinct.pluck(:organization_id).to_set
    rows = Organization.pluck(:id).reject { |id| already.include?(id) }.map do |organization_id|
      {
        # throttle a 1h (non i 5' di default): il rilevamento gira ogni 15' e una macchina morta resta morta,
        # quindi il throttle collassa i re-alert in ~1/h. Coerente con Alerting::Rules::InstallDefaults.
        organization_id: organization_id, event_type: EVENT_TYPE, name: NAME,
        enabled: true, throttle_seconds: 3600, unhandled_only: false, created_at: now, updated_at: now
      }
    end
    Rule.insert_all(rows) if rows.any?
  end

  def down
    # Non distinguiamo le regole seminate da quelle create a mano nel frattempo → down non ripristinabile.
  end
end
