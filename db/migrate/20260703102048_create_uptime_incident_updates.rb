# frozen_string_literal: true

# Uno step della timeline di un incident narrato (detected → investigating → fixing → monitoring →
# resolved). Umano, creato da un account; body opzionale (precompilato lato UI). Pattern Ticketing::Event.
class CreateUptimeIncidentUpdates < ActiveRecord::Migration[8.1]
  def change
    create_table :uptime_incident_updates, id: :uuid do |t|
      t.timestamps
      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :incident, type: :uuid, null: false, index: true,
                   foreign_key: { to_table: :uptime_incidents, on_delete: :cascade }

      t.integer :phase, null: false
      t.text :body
    end
  end
end
