class BackfillServerAlertingRules < ActiveRecord::Migration[8.1]
  # Gemella di BackfillUptimeAlertingRules (CYRA-207): le regole di alerting nascono solo su richiesta,
  # così NESSUNA org aveva una regola per gli eventi dei server e degli agenti — una macchina che cade la
  # notte veniva segnata down sul pannello ma non avvisava nessuno (CYRA-242). Installa le regole di
  # default mancanti (org-wide, attive) su TUTTE le org esistenti; le org nuove le ricevono dal
  # provisioning (Alerting::Rules::InstallDefaults). Idempotente.
  # SOLO gli eventi org-scoped SENZA soglia: down/up/service_failed/smart_failing/db_down + agenti fermi.
  # Le soglie disco/temperatura/cpu/mem restano una scelta esplicita (richiedono un valore).
  # event_type resta l'intero grezzo così la migrazione è autoconsistente se l'enum del modello evolve.
  DEFAULTS = {
    7  => "Server down",             # server_down
    8  => "Server recovered",        # server_up
    13 => "Systemd service failed",  # server_service_failed
    14 => "SMART failing",           # server_smart_failing
    17 => "Database unreachable",    # server_db_down
    20 => "Automation stalled"       # agents_stalled
  }.freeze

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
      # Eventi ORG-SCOPED (server_*/agents_stalled): Alerting::Evaluate li valuta ignorando
      # project/environment, quindi QUALSIASI regola per quell'evento (anche scoped a mano) copre già
      # tutta l'org → conta come installata e blocca il doppione. Niente filtro sullo scope, a differenza
      # del backfill uptime dove solo la org-wide copre tutti i monitor.
      existing = Rule.where(organization_id: organization_id, event_type: DEFAULTS.keys).pluck(:event_type)
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
