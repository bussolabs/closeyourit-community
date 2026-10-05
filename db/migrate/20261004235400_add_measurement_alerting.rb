class AddMeasurementAlerting < ActiveRecord::Migration[8.1]
  def change
    add_column :alerting_rules, :measurement_series_id, :uuid
    add_column :alerting_rules, :measurement_config, :jsonb, null: false, default: {}
    add_column :alerting_rules, :measurement_state, :jsonb, null: false, default: {}
    add_index :alerting_rules, :measurement_series_id
    add_foreign_key :alerting_rules, :measurements_series, column: :measurement_series_id, on_delete: :nullify
    # The simple FK clears only the series; deferred tenant binding preserves project scope.
    add_foreign_key :alerting_rules, :measurements_series, column: [ :measurement_series_id, :project_id ], primary_key: [ :id, :project_id ], deferrable: :deferred
    add_check_constraint :alerting_rules, "event_type <> 59 OR project_id IS NOT NULL", name: "measurement_rule_project"
    add_check_constraint :alerting_rules, "octet_length(measurement_config::text) <= 4096", name: "measurement_config_budget"

    create_table :alerting_evaluations, id: :uuid do |t|
      t.timestamps
      t.references :rule, type: :uuid, null: false, foreign_key: { to_table: :alerting_rules, on_delete: :cascade }
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects, on_delete: :cascade }
      t.uuid :series_id, null: false
      t.string :config_digest, null: false, limit: 64
      t.decimal :window_end_ns, precision: 20, scale: 0, null: false
      t.jsonb :result, null: false, default: {}
      t.string :status, null: false
      t.string :dispatch_state, null: false, default: "none"
      t.datetime :dispatch_until
      t.datetime :retry_at
      t.index [ :rule_id, :config_digest, :series_id, :window_end_ns ], unique: true, name: "measurement_evaluation_identity"
      t.index [ :dispatch_state, :retry_at ]
      t.check_constraint "window_end_ns BETWEEN 0 AND 18446744073709551615", name: "measurement_evaluation_time"
      t.check_constraint "status IN ('unknown', 'firing', 'safe')", name: "measurement_evaluation_status"
      t.check_constraint "dispatch_state IN ('none', 'pending', 'delivering', 'delivered', 'cancelled')", name: "measurement_evaluation_dispatch"
      t.check_constraint "octet_length(result::text) <= 16384", name: "measurement_evaluation_budget"
    end
  end
end
