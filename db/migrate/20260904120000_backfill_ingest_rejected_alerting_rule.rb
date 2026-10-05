# frozen_string_literal: true

# CYRA-775 — l'avviso «Dati delle macchine respinti» diventa default per le organizzazioni nuove via
# Alerting::Rules::InstallDefaults, ma quelle esistenti resterebbero scoperte: l'evento verrebbe
# generato e buttato via da Alerting::Evaluate, che senza regola non trova destinatari. Sarebbe il
# peggiore dei casi — le macchine non vengono più dichiarate giù per un rifiuto nostro, e nessuno
# saprebbe perché. Stesso pattern del backfill di CYRA-676 (20260828121000).
class BackfillIngestRejectedAlertingRule < ActiveRecord::Migration[8.1]
  # Intero grezzo append-only di Alerting::Rule: 51 = server_ingest_rejected.
  EVENT_TYPE = 51
  NAME = "Dati delle macchine respinti"
  # Un episodio di rifiuti dura decine di minuti e il giro che se ne accorge gira ogni minuto: col
  # freno di default (5') lo stesso avviso arriverebbe una volta al minuto. Stesso valore che
  # ricevono le organizzazioni nuove da InstallDefaults.
  THROTTLE_SECONDS = 3600

  class Organization < ActiveRecord::Base
    self.table_name = "organizations"
  end

  class Rule < ActiveRecord::Base
    self.table_name = "alerting_rules"
  end

  def up
    Rule.reset_column_information
    now = Time.current
    already = Rule.where(event_type: EVENT_TYPE).distinct.pluck(:organization_id).to_set

    rows = Organization.pluck(:id).reject { |id| already.include?(id) }.map do |organization_id|
      {
        organization_id: organization_id,
        event_type: EVENT_TYPE,
        name: NAME,
        enabled: true,
        throttle_seconds: THROTTLE_SECONDS,
        unhandled_only: false,
        created_at: now,
        updated_at: now
      }
    end
    Rule.insert_all(rows) if rows.any?
  end

  def down
    # Le regole possono essere state modificate dall'utente: non è sicuro distinguerle e rimuoverle.
  end
end
