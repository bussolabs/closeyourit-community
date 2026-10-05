# frozen_string_literal: true

# Banner per-monitor mostrato sulla status page pubblica (manutenzioni/avvisi). Un solo banner per
# monitor (indice unico su monitor_id): livello + messaggio + finestra opzionale start/end + attivo.
class CreateUptimeAnnouncements < ActiveRecord::Migration[8.1]
  def change
    create_table :uptime_announcements, id: :uuid do |t|
      t.timestamps
      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :monitor, type: :uuid, null: false, index: { unique: true },
                   foreign_key: { to_table: :uptime_monitors, on_delete: :cascade }

      t.integer :level, null: false, default: 0
      t.text :message, null: false
      t.datetime :starts_at
      t.datetime :ends_at
      t.boolean :active, null: false, default: true
    end
  end
end
