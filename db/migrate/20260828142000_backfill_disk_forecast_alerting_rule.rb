# frozen_string_literal: true

# CYRA-679 — regola default del predittivo disco per le organizzazioni esistenti (stesso pattern dei
# backfill 20260828090000 e 20260828121000: le org nuove la ricevono da InstallDefaults, quelle
# esistenti resterebbero scoperte e l'evento verrebbe generato e buttato via).
class BackfillDiskForecastAlertingRule < ActiveRecord::Migration[8.1]
  # Intero grezzo append-only di Alerting::Rule: 48 = server_disk_forecast.
  EVENT_TYPE = 48
  NAME = "Spazio dati in esaurimento"

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
      { organization_id: organization_id, event_type: EVENT_TYPE, name: NAME, enabled: true,
        throttle_seconds: 300, unhandled_only: false, created_at: now, updated_at: now }
    end
    Rule.insert_all(rows) if rows.any?
  end

  def down
    # Le regole possono essere state modificate dall'utente: non è sicuro distinguerle e rimuoverle.
  end
end
