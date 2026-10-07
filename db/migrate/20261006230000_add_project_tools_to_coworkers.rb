# Puckies read project data and propose changes under rules (CYRA-1009, CYRA-1010, CYRA-1017).
class AddProjectToolsToCoworkers < ActiveRecord::Migration[8.1]
  def change
    add_column :coworkers_runs, :scope, :jsonb, null: false, default: {}

    create_table :coworkers_tool_calls, id: :uuid do |t|
      t.references :run, type: :uuid, null: false, foreign_key: { to_table: :coworkers_runs, on_delete: :cascade }
      t.string :call_id, null: false
      t.string :name, null: false
      t.string :args_digest, null: false
      t.jsonb :result, null: false, default: {}
      t.timestamps
    end
    add_index :coworkers_tool_calls, %i[run_id call_id], unique: true

    create_table :coworkers_rules, id: :uuid do |t|
      t.references :puck, type: :uuid, null: false, foreign_key: { to_table: :coworkers_puckies, on_delete: :cascade }
      t.string :action, null: false
      t.string :decision, null: false
      t.timestamps
    end
    add_index :coworkers_rules, %i[puck_id action], unique: true
    add_check_constraint :coworkers_rules, "decision IN ('allow', 'ask', 'deny')", name: "coworkers_rules_decision_valid"

    change_column_null :assistant_proposals, :message_id, true
    add_reference :assistant_proposals, :coworkers_run, type: :uuid, foreign_key: { on_delete: :cascade }
    add_column :assistant_proposals, :origin, :string, null: false, default: "user"
    add_reference :assistant_proposals, :coworkers_rule, type: :uuid, foreign_key: { on_delete: :nullify }
    add_check_constraint :assistant_proposals, "num_nonnulls(message_id, coworkers_run_id) = 1",
      name: "assistant_proposals_one_parent"
    add_check_constraint :assistant_proposals, "origin IN ('user', 'rule')", name: "assistant_proposals_origin_valid"
  end
end
