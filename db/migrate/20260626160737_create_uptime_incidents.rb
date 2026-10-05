# frozen_string_literal: true

class CreateUptimeIncidents < ActiveRecord::Migration[8.1]
  def change
    create_table :uptime_incidents, id: :uuid do |t|
      t.timestamps

      t.references :monitor, type: :uuid, null: false,
                   foreign_key: { to_table: :uptime_monitors, on_delete: :cascade }

      t.datetime :started_at,  null: false
      t.datetime :resolved_at              # nil mentre l'incident è aperto (down)

      t.index %i[monitor_id resolved_at]
    end
  end
end
