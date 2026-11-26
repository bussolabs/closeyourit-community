# frozen_string_literal: true

# CYRA-1154 — one check per delivered pull request and main change: does it still merge?
# The unique index is the first guard against a second rework for the same pair.
class CreateAgentsConflictChecks < ActiveRecord::Migration[8.1]
  def change
    create_table :agents_conflict_checks, id: :uuid do |t|
      t.uuid :workflow_id, null: false
      t.uuid :delivery_candidate_id, null: false
      t.string :repository_full_name, null: false
      t.integer :number, null: false
      t.string :main_sha, null: false
      t.integer :state, null: false, default: 0
      t.integer :attempts, null: false, default: 0
      t.datetime :next_check_at
      t.datetime :last_checked_at
      t.string :last_error_code
      t.jsonb :main_titles, null: false, default: []
      t.integer :main_commits_count, null: false, default: 0
      t.datetime :handled_at
      t.timestamps
    end

    add_index :agents_conflict_checks, %i[delivery_candidate_id main_sha], unique: true,
              name: "index_agents_conflict_checks_identity"
    add_index :agents_conflict_checks, :next_check_at, where: "state = 0",
              name: "index_agents_conflict_checks_due"
    add_index :agents_conflict_checks, :workflow_id
    add_foreign_key :agents_conflict_checks, :agents_workflows, column: :workflow_id, on_delete: :cascade
    add_foreign_key :agents_conflict_checks, :agents_delivery_candidates, column: :delivery_candidate_id,
                                                                          on_delete: :cascade
  end
end
