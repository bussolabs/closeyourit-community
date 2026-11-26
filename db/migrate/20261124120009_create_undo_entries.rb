# frozen_string_literal: true

# CYRA-1150 — what a bulk action changed, kept for a few seconds so its author can undo it.
class CreateUndoEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :undo_entries, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.jsonb :items, null: false, default: []
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false
      t.index :expires_at
      t.check_constraint "kind IN ('error_groups', 'metric_groups', 'notifications')", name: "undo_entries_kind_valid"
      t.check_constraint "jsonb_typeof(items) = 'array'", name: "undo_entries_items_array"
    end
  end
end
