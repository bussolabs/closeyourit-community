# frozen_string_literal: true

class BackfillContainerDownAlertingRule < ActiveRecord::Migration[8.1]
  # CYRA-248: server_container_down (intero 21) è un evento org-scoped SENZA soglia nato DOPO
  # BackfillServerAlertingRules (CYRA-242), che non lo includeva. Le regole di alerting nascono solo su
  # richiesta, quindi NESSUNA org esistente avrebbe una regola per la caduta di un container e la
  # sparizione non avviserebbe nessuno. Installa la regola di default (org-wide, attiva) sulle org che
  # non ce l'hanno già; le org nuove la ricevono dal provisioning (Alerting::Rules::InstallDefaults).
  # Idempotente. event_type resta l'intero grezzo così la migrazione è autoconsistente se l'enum evolve.
  EVENT_TYPE = 21
  NAME = "Container down"

  class Organization < ActiveRecord::Base
    self.table_name = "organizations"
  end

  class Rule < ActiveRecord::Base
    self.table_name = "alerting_rules"
  end

  def up
    Rule.reset_column_information
    now = Time.current

    # Eventi ORG-SCOPED (server_*): Alerting::Evaluate li valuta ignorando project/environment, quindi
    # QUALSIASI regola per quell'evento copre già tutta l'org → conta come installata e blocca il doppione.
    already = Rule.where(event_type: EVENT_TYPE).distinct.pluck(:organization_id).to_set
    rows = Organization.pluck(:id).reject { |id| already.include?(id) }.map do |organization_id|
      {
        organization_id: organization_id, event_type: EVENT_TYPE, name: NAME,
        enabled: true, throttle_seconds: 300, unhandled_only: false, created_at: now, updated_at: now
      }
    end
    Rule.insert_all(rows) if rows.any?
  end

  def down
    # Non distinguiamo le regole seminate da quelle create a mano nel frattempo → down non ripristinabile.
  end
end
