# frozen_string_literal: true

# Ripara lo stato lasciato dalla race pre-lock (CYRA-269): monitor con più incident aperti di primo
# livello. Tiene aperto il più vecchio (la finestra di downtime reale) e chiude gli altri. NON tocca i
# figli di un raggruppamento (parent_id NOT NULL), che possono restare legittimamente aperti.
class CloseDuplicateOpenIncidents < ActiveRecord::Migration[8.1]
  def up
    execute(<<~SQL.squish)
      UPDATE uptime_incidents SET resolved_at = NOW(), updated_at = NOW()
      WHERE resolved_at IS NULL AND parent_id IS NULL AND id NOT IN (
        SELECT DISTINCT ON (monitor_id) id FROM uptime_incidents
        WHERE resolved_at IS NULL AND parent_id IS NULL ORDER BY monitor_id, started_at ASC, id ASC
      )
    SQL
  end

  def down
    # Data cleanup una tantum: gli incident chiusi non si riaprono.
  end
end
