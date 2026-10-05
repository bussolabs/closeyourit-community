# frozen_string_literal: true

class CreateUptimeMonitors < ActiveRecord::Migration[8.1]
  def change
    create_table :uptime_monitors, id: :uuid do |t|
      t.timestamps

      t.references :project, type: :uuid, null: false,
                   foreign_key: { to_table: :projects, on_delete: :cascade }
      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.string  :name,   null: false
      t.string  :url,    null: false
      t.string  :http_method,     null: false, default: "GET"
      t.integer :interval_seconds, null: false, default: 60
      t.integer :expected_status,  null: false, default: 200
      t.integer :timeout_seconds,  null: false, default: 5
      t.boolean :active, null: false, default: true
      # Salute corrente — gestita dal sistema (workflow tecnico): enum unknown/up/down.
      t.integer :current_status, null: false, default: 0
      t.datetime :last_checked_at

      t.index %i[project_id active]
    end
  end
end
