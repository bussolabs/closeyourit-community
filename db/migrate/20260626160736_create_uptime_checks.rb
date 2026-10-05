# frozen_string_literal: true

class CreateUptimeChecks < ActiveRecord::Migration[8.1]
  def change
    create_table :uptime_checks, id: :uuid do |t|
      # Check immutabile: solo created_at.
      t.datetime :created_at, null: false

      t.references :monitor, type: :uuid, null: false,
                   foreign_key: { to_table: :uptime_monitors, on_delete: :cascade }

      t.boolean  :up, null: false
      t.integer  :status_code        # nil su timeout/connection error
      t.integer  :response_time_ms    # nil se non raggiunto
      t.string   :error               # es. "timeout", "connection refused"
      t.datetime :checked_at, null: false

      t.index %i[monitor_id checked_at]
    end
  end
end
