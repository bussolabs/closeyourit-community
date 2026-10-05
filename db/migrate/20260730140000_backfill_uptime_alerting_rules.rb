class BackfillUptimeAlertingRules < ActiveRecord::Migration[8.1]
  # Le regole di alerting nascono solo su richiesta (nessun seed le installava): così NESSUNA org aveva
  # una regola per gli eventi uptime e una caduta apriva l'incident sulla status page ma non avvisava
  # nessuno (CYRA-207). Installa le regole di default mancanti (org-wide, attive) su TUTTE le org
  # esistenti; le org nuove le ricevono dal provisioning (Alerting::Rules::InstallDefaults). Idempotente.
  # event_type resta l'intero grezzo così la migrazione è autoconsistente se l'enum del modello evolve.
  DEFAULTS = { 2 => "Uptime down", 3 => "Uptime up" }.freeze # 2 = uptime_down, 3 = uptime_up

  class Organization < ActiveRecord::Base
    self.table_name = "organizations"
  end

  class Rule < ActiveRecord::Base
    self.table_name = "alerting_rules"
  end

  def up
    Rule.reset_column_information
    now = Time.current

    Organization.pluck(:id).each do |organization_id|
      # Solo le regole ORG-WIDE (project/environment nil) coprono tutti i monitor: una regola scoped su un
      # progetto/ambiente non basta e non blocca l'installazione della org-wide mancante.
      existing = Rule.where(organization_id: organization_id, event_type: DEFAULTS.keys,
                            project_id: nil, environment_id: nil).pluck(:event_type)
      rows = (DEFAULTS.keys - existing).map do |event_type|
        {
          organization_id: organization_id, event_type: event_type, name: DEFAULTS.fetch(event_type),
          enabled: true, throttle_seconds: 300, unhandled_only: false, created_at: now, updated_at: now
        }
      end
      Rule.insert_all(rows) if rows.any?
    end
  end

  def down
    # Non distinguiamo le regole seminate da quelle create a mano nel frattempo → down non ripristinabile.
  end
end
