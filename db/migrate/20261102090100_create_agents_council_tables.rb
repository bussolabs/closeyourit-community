# frozen_string_literal: true

# One council slice per project and day, and the proposals it judged (CYRA-1133).
class CreateAgentsCouncilTables < ActiveRecord::Migration[8.1]
  def change
    create_table :agents_council_runs, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :host, type: :uuid, null: false, foreign_key: { to_table: :agents_hosts }
      t.string :mode, null: false
      t.string :status, null: false, default: "running"
      t.string :failure_kind
      t.text :failure
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.jsonb :report, null: false, default: {}
      t.timestamps
      t.index %i[organization_id status started_at]
      t.index %i[project_id started_at]
      t.index :organization_id, unique: true, where: "status = 'running'", name: "index_agents_council_runs_one_running_per_org"
      t.check_constraint "status IN ('running', 'completed', 'failed')", name: "agents_council_runs_status_valid"
    end

    create_table :agents_council_proposals, id: :uuid do |t|
      t.references :council_run, type: :uuid, null: false, foreign_key: { to_table: :agents_council_runs, on_delete: :cascade }
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :ref, null: false
      t.string :proposer, null: false
      t.string :title, null: false
      t.text :problem, null: false
      t.text :solution
      t.string :kind
      t.string :risk
      t.string :suggested_engine
      t.string :suggested_model
      t.jsonb :critique, null: false, default: {}
      t.string :outcome, null: false
      t.string :reasons, array: true, null: false, default: []
      t.references :ticket, type: :uuid, foreign_key: { to_table: :ticketing_tickets, on_delete: :nullify }, index: { unique: true }
      t.references :idea, type: :uuid, foreign_key: { to_table: :ideas_ideas, on_delete: :nullify }
      t.timestamps
      t.index %i[council_run_id ref], unique: true
    end
  end
end
