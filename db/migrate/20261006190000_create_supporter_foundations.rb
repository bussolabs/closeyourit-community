# frozen_string_literal: true

# CYAU-235 — the supporter's foundations, all switched off: its engine (organization default, machine
# override), the reserved topics the organization and each project add to the built-in ones, the
# per-project switch, and the ledger of the decisions it takes alone until a person marks them seen.
class CreateSupporterFoundations < ActiveRecord::Migration[8.1]
  ENGINES = "'claude', 'codex', 'opencode'"

  def change
    change_table :agents_automator_settings, bulk: true do |t|
      t.string :supporter, null: false, default: "codex"
      t.text :supporter_reserved_topics
      t.check_constraint "supporter IN (#{ENGINES})", name: "agents_automator_settings_supporter_valid"
    end

    change_table :agents_hosts, bulk: true do |t|
      t.string :supporter
      t.check_constraint "supporter IS NULL OR supporter IN (#{ENGINES})", name: "agents_hosts_supporter_valid"
    end

    change_table :projects, bulk: true do |t|
      t.boolean :supporter_enabled, null: false, default: false
      t.text :supporter_reserved_topics
    end

    create_table :agents_supporter_decisions, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :workflow, type: :uuid, null: false, foreign_key: { to_table: :agents_workflows, on_delete: :cascade }
      t.string :target_type, null: false
      t.uuid :target_id, null: false
      t.string :target_digest, null: false
      t.string :outcome, null: false
      t.string :engine, null: false
      t.integer :risk_score, null: false
      t.jsonb :evidence, null: false, default: {}
      t.datetime :seen_at
      t.references :seen_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.timestamps

      t.index %i[target_type target_id target_digest], unique: true, name: "index_agents_supporter_decisions_on_target"
      t.index %i[organization_id seen_at], name: "index_agents_supporter_decisions_to_review"
      t.check_constraint "target_type IN ('question', 'plan')", name: "agents_supporter_decisions_target_type_valid"
      t.check_constraint "outcome IN ('answered', 'approved', 'escalated')", name: "agents_supporter_decisions_outcome_valid"
      t.check_constraint "engine IN (#{ENGINES})", name: "agents_supporter_decisions_engine_valid"
      t.check_constraint "risk_score BETWEEN 1 AND 10", name: "agents_supporter_decisions_risk_score_range"
    end
  end
end
