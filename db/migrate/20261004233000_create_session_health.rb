# frozen_string_literal: true

class CreateSessionHealth < ActiveRecord::Migration[8.1]
  def change
    create_table :session_health_sessions, id: :uuid do |t|
      t.timestamps
      t.references :project, null: false, type: :uuid, foreign_key: { to_table: :projects, on_delete: :cascade }
      t.uuid :sid, null: false
      t.boolean :producer_identity, null: false, default: true
      t.string :release, null: false
      t.string :environment
      t.datetime :started_at, null: false
      t.decimal :started_unix_nano, precision: 20, scale: 0, null: false
      t.decimal :update_unix_nano, precision: 20, scale: 0, null: false
      t.decimal :sequence, precision: 20, scale: 0, null: false
      t.string :status, null: false
      t.decimal :errors, precision: 20, scale: 0, null: false, default: 0
      t.float :duration
      t.string :abnormal_mechanism
      t.boolean :initialization_seen, null: false, default: false
      t.integer :observed_update_count, null: false, default: 1
      t.string :payload_digest, null: false, limit: 64
    end
    add_index :session_health_sessions, [ :project_id, :sid ], unique: true
    add_index :session_health_sessions, [ :project_id, :release, :environment, :started_at ], name: "session_health_sessions_summary"
    add_index :session_health_sessions, :created_at
    add_check_constraint :session_health_sessions, "status IN ('ok','exited','crashed','abnormal','unhandled')", name: "session_health_valid_status"
    %i[started_unix_nano update_unix_nano sequence errors].each do |column|
      add_check_constraint :session_health_sessions, "#{column} BETWEEN 0 AND 18446744073709551615", name: "session_health_valid_#{column}"
    end
    add_check_constraint :session_health_sessions, "duration IS NULL OR (duration >= 0 AND duration < 'Infinity'::float)", name: "session_health_valid_duration"
    add_check_constraint :session_health_sessions, "observed_update_count > 0", name: "session_health_valid_update_count"

    create_table :session_health_aggregates, id: :uuid do |t|
      t.timestamps
      t.references :project, null: false, type: :uuid, foreign_key: { to_table: :projects, on_delete: :cascade }
      t.string :release, null: false
      t.string :environment
      t.datetime :started_at, null: false
      %i[exited errored unhandled crashed abnormal].each { |column| t.decimal column, precision: 20, scale: 0, null: false, default: 0 }
    end
    add_index :session_health_aggregates, [ :project_id, :release, :environment, :started_at ], name: "session_health_aggregates_summary"
    add_index :session_health_aggregates, :created_at
    %i[exited errored unhandled crashed abnormal].each do |column|
      add_check_constraint :session_health_aggregates, "#{column} BETWEEN 0 AND 18446744073709551615", name: "session_health_valid_aggregate_#{column}"
    end
    add_column :settings_global, :session_health_retention_days, :integer, null: false, default: 30
    add_check_constraint :settings_global, "session_health_retention_days BETWEEN 1 AND 365", name: "settings_session_health_retention_range"
  end
end
