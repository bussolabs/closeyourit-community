# frozen_string_literal: true

class CreateAgentsLimits < ActiveRecord::Migration[8.0]
  def change
    create_table :agents_limit_policies, id: :uuid do |t|
      t.timestamps
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, null: true, foreign_key: { on_delete: :cascade }
      t.string :runtime
      t.integer :max_parallel
      t.integer :max_daily_runs
      t.decimal :max_daily_cost, precision: 14, scale: 4
      t.integer :max_runtime_seconds
      t.boolean :stop_dispatch, null: false, default: false
      t.integer :max_age_seconds, null: false, default: 60

      t.index %i[organization_id project_id runtime], unique: true, nulls_not_distinct: true,
                                                      name: "index_agents_limit_policies_scope"
      t.check_constraint "max_parallel IS NULL OR max_parallel >= 0", name: "agents_limit_policy_parallel_nonnegative"
      t.check_constraint "max_daily_runs IS NULL OR max_daily_runs >= 0", name: "agents_limit_policy_runs_nonnegative"
      t.check_constraint "max_daily_cost IS NULL OR max_daily_cost >= 0", name: "agents_limit_policy_cost_nonnegative"
      t.check_constraint "max_runtime_seconds IS NULL OR max_runtime_seconds > 0",
                         name: "agents_limit_policy_runtime_positive"
      t.check_constraint "max_age_seconds > 0", name: "agents_limit_policy_age_positive"
    end

    create_table :agents_limit_usages, id: :uuid do |t|
      t.timestamps
      t.references :policy, type: :uuid, null: false,
                            foreign_key: { to_table: :agents_limit_policies, on_delete: :cascade }
      t.date :period_on, null: false
      t.integer :runs, null: false, default: 0
      t.decimal :cost, precision: 14, scale: 4, null: false, default: 0

      t.index %i[policy_id period_on], unique: true
      t.check_constraint "runs >= 0", name: "agents_limit_usage_runs_nonnegative"
      t.check_constraint "cost >= 0", name: "agents_limit_usage_cost_nonnegative"
    end

    create_table :agents_limit_reservations, id: :uuid do |t|
      t.timestamps
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, null: true, foreign_key: { on_delete: :nullify }
      t.references :host, type: :uuid, null: false,
                          foreign_key: { to_table: :agents_hosts, on_delete: :cascade }
      t.references :agent, type: :uuid, null: false,
                           foreign_key: { to_table: :agents_agents, on_delete: :cascade }
      t.string :runtime, null: false
      t.string :idempotency_key, null: false
      t.integer :requested_ttl_seconds, null: false
      t.decimal :estimated_cost, precision: 14, scale: 4, null: false, default: 0
      t.string :outcome, null: false
      t.string :denial_reason
      t.datetime :expires_at

      t.index %i[organization_id idempotency_key], unique: true,
                                                       name: "index_agents_limit_reservations_idempotency"
      t.index %i[organization_id project_id runtime expires_at],
              name: "index_agents_limit_reservations_active_scope"
      t.index %i[organization_id expires_at], where: "outcome = 'granted'",
                                                   name: "index_agents_limit_reservations_active_organization"
      t.check_constraint "requested_ttl_seconds > 0", name: "agents_limit_reservation_ttl_positive"
      t.check_constraint "estimated_cost >= 0", name: "agents_limit_reservation_cost_nonnegative"
      t.check_constraint "outcome IN ('granted', 'denied')", name: "agents_limit_reservation_outcome"
      t.check_constraint "(outcome = 'granted' AND expires_at IS NOT NULL AND denial_reason IS NULL) OR " \
                         "(outcome = 'denied' AND expires_at IS NULL AND denial_reason IS NOT NULL)",
                         name: "agents_limit_reservation_decision_shape"
    end
  end
end
