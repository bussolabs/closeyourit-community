# frozen_string_literal: true

class BackfillAnalyticsIdeaWorkloadDatasetAlertingRules < ActiveRecord::Migration[8.1]
  # CYRA-147: statistiche, idee, attività e dataset portano SEI nuovi tipi di evento, nati DOPO i backfill
  # precedenti (CYRA-207 uptime, CYRA-242 server, CYRA-248 container, CYRA-282 host). Le regole di alerting
  # nascono solo su richiesta (Alerting::Rules::InstallDefaults, chiamato dal provisioning e dall'iscrizione),
  # quindi NESSUNA org esistente avrebbe una regola per questi eventi: il detector/servizio accoderebbe
  # l'allarme e Alerting::Evaluate, non trovando regole, non avviserebbe NESSUNO — la funzionalità nascerebbe
  # morta per tutti gli utenti attuali. Installa le regole di default mancanti (org-wide, attive) su TUTTE le
  # org esistenti; le org nuove le ricevono dal provisioning. Idempotente: non duplica e non tocca le regole
  # già presenti, nemmeno quelle disattivate o rinominate a mano. Il PICCO di traffico
  # (analytics_traffic_spike, 25) resta opt-in come in InstallDefaults: spesso è benigno (campagna, bot).
  # event_type resta l'intero grezzo così la migrazione è autoconsistente se l'enum del modello evolve.
  # I valori partono da 24 perché il 23 è uptime_slow (CYRA-151), arrivato su main insieme a questo lavoro.

  # Eventi PROJECT-SCOPED: Alerting::Evaluate#matching_rules li seleziona a partire dal progetto, quindi
  # solo una regola ORG-WIDE (project/environment nil) copre tutti i progetti — una scoped lascerebbe gli
  # altri scoperti e NON conta come installata (stessa scelta del backfill uptime).
  PROJECT_SCOPED = {
    24 => "Traffic drop",       # analytics_traffic_drop
    26 => "New idea",           # idea_created
    27 => "New idea comment",   # idea_commented
    29 => "Training completed", # dataset_training_completed
    30 => "Training failed"     # dataset_training_failed
  }.freeze

  # Evento ORG-SCOPED: Alerting::Evaluate#matching_org_rules IGNORA project/environment, quindi QUALSIASI
  # regola per quell'evento (anche scoped a mano) copre già tutta l'org → conta come installata e blocca
  # il doppione.
  ORG_SCOPED = { 28 => "Task due soon" }.freeze # workload_due_soon

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
      rows = missing_event_types(organization_id).map do |event_type|
        {
          organization_id: organization_id, event_type: event_type, name: name_for(event_type),
          enabled: true, throttle_seconds: 300, unhandled_only: false, created_at: now, updated_at: now
        }
      end
      Rule.insert_all(rows) if rows.any?
    end
  end

  def down
    # Non distinguiamo le regole seminate da quelle create a mano nel frattempo → down non ripristinabile.
  end

  private

  def missing_event_types(organization_id)
    org_wide = Rule.where(organization_id: organization_id, event_type: PROJECT_SCOPED.keys,
                          project_id: nil, environment_id: nil).pluck(:event_type)
    any_scope = Rule.where(organization_id: organization_id, event_type: ORG_SCOPED.keys).pluck(:event_type)

    (PROJECT_SCOPED.keys - org_wide) + (ORG_SCOPED.keys - any_scope)
  end

  def name_for(event_type) = PROJECT_SCOPED[event_type] || ORG_SCOPED.fetch(event_type)
end
