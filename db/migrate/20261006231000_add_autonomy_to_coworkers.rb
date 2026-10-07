# Puckies work alone within limits: budgets, schedules, watch and learned memory
# (CYRA-1027, CYRA-1001, CYRA-1011, CYRA-1012).
class AddAutonomyToCoworkers < ActiveRecord::Migration[8.1]
  def change
    create_table :coworkers_budgets, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.bigint :monthly_token_cap
      t.timestamps
    end

    create_table :coworkers_schedules, id: :uuid do |t|
      t.references :puck, type: :uuid, null: false, foreign_key: { to_table: :coworkers_puckies, on_delete: :cascade }
      t.references :created_by, type: :uuid, null: false, foreign_key: { to_table: :accounts }
      t.text :input, null: false
      t.string :frequency, null: false
      t.integer :hour, null: false, default: 8
      t.integer :minute, null: false, default: 0
      t.integer :weekday
      t.string :time_zone, null: false
      t.boolean :paused, null: false, default: false
      t.datetime :next_run_at, null: false
      t.timestamps
    end
    add_index :coworkers_schedules, :next_run_at
    add_check_constraint :coworkers_schedules, "frequency IN ('hourly', 'daily', 'weekdays', 'weekly')", name: "coworkers_schedules_frequency_valid"

    add_column :coworkers_runs, :tokens_used, :integer, null: false, default: 0
    add_column :coworkers_runs, :tokens_reserved, :integer, null: false, default: 0
    add_column :coworkers_runs, :slot_at, :datetime
    add_reference :coworkers_runs, :schedule, type: :uuid, foreign_key: { to_table: :coworkers_schedules, on_delete: :nullify }, index: false
    add_index :coworkers_runs, %i[schedule_id slot_at], unique: true, where: "schedule_id IS NOT NULL"

    add_column :coworkers_puckies, :watch_every_minutes, :integer
    add_column :coworkers_puckies, :watch_next_at, :datetime
    add_column :coworkers_puckies, :watch_state, :jsonb, null: false, default: {}

    create_table :coworkers_memory_notes, id: :uuid do |t|
      t.references :puck, type: :uuid, null: false, foreign_key: { to_table: :coworkers_puckies, on_delete: :cascade }
      t.references :run, type: :uuid, foreign_key: { to_table: :coworkers_runs, on_delete: :nullify }
      t.text :body, null: false
      t.string :status, null: false, default: "pending"
      t.jsonb :scope, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :coworkers_memory_notes, "status IN ('pending', 'active', 'dismissed')", name: "coworkers_memory_notes_status_valid"
  end
end
