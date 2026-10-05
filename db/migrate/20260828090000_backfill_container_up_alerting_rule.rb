# frozen_string_literal: true

# CYRA-514 — l'avviso di rientro dei contenitori esiste dal 12 agosto ma sulle organizzazioni
# GIÀ ESISTENTI non ha mai avuto una regola: il backfill c'era per «contenitore caduto»
# (20260806201537) e per i sette eventi 36-42 (20260812011000), non per il 35.
#
# Effetto in produzione: quando un contenitore torna su, nessuno lo sa. Sul feed la caduta resta
# l'ultima parola anche a guasto chiuso — è esattamente il motivo per cui la regola è un default
# per le organizzazioni nuove (Alerting::Rules::InstallDefaults).
class BackfillContainerUpAlertingRule < ActiveRecord::Migration[8.1]
  # Intero grezzo append-only di Alerting::Rule: il 35 è server_container_up. La migrazione non
  # dipende dal model applicativo, che può cambiare senza che la storia debba seguirlo.
  EVENT_TYPE = 35
  NAME = "Contenitori tornati su"

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
        throttle_seconds: 300,
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
