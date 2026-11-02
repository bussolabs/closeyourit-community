# frozen_string_literal: true

# What an agent does while it works a ticket, step by step, and whether a project lets its code be kept (CYAU-282).
class CreateAgentsAttemptLiveEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :agents_attempt_live_events, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :attempt, type: :uuid, null: false, index: false,
                             foreign_key: { to_table: :agents_attempts, on_delete: :cascade }
      t.integer :seq, null: false
      t.string :kind, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :recorded_at, null: false
      t.datetime :created_at, null: false
      t.index %i[attempt_id seq], unique: true
      t.index :created_at
      t.check_constraint "seq > 0", name: "agents_attempt_live_events_seq_positive"
      t.check_constraint "kind IN ('file_change', 'file_read', 'search', 'command', 'truncated')",
                         name: "agents_attempt_live_events_kind_valid"
    end

    add_column :projects, :automator_live_code_enabled, :boolean, null: false, default: false
  end
end
