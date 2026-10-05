# frozen_string_literal: true

class CreateMeasurementPersistence < ActiveRecord::Migration[8.1]
  def change
    create_table :measurements_series, id: :uuid do |t|
      t.timestamps
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects, on_delete: :cascade }
      t.string :identity_digest, limit: 64, null: false
      t.string :name, null: false
      t.string :unit, null: false, default: ""
      t.string :description, null: false, default: ""
      t.string :metric_type, null: false
      t.integer :temporality, null: false, default: 0
      t.boolean :monotonic, null: false, default: false
      t.jsonb :resource, null: false, default: {}
      t.jsonb :instrumentation_scope, null: false, default: {}
      t.jsonb :point_attributes, null: false, default: []
      t.string :resource_schema_url, null: false, default: ""
      t.string :scope_schema_url, null: false, default: ""
      t.datetime :first_received_at, null: false
      t.datetime :last_admitted_at, null: false
      t.index [ :project_id, :identity_digest ], unique: true, name: "measurements_series_identity"
      t.index [ :id, :project_id ], unique: true, name: "measurements_series_tenant_identity"
      t.index [ :project_id, :last_admitted_at, :id ], name: "measurements_series_activity"
    end
    add_check_constraint :measurements_series, "metric_type IN ('gauge', 'sum', 'histogram', 'exponentialHistogram')", name: "measurements_series_valid_type"
    add_check_constraint :measurements_series, "(metric_type = 'gauge' AND temporality = 0 AND NOT monotonic) OR (metric_type <> 'gauge' AND temporality IN (1, 2))", name: "measurements_series_valid_temporality"

    create_table :measurements_points, id: :uuid do |t|
      t.timestamps
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects, on_delete: :cascade }
      t.uuid :series_id, null: false
      t.decimal :start_time_unix_nano, precision: 20, scale: 0, null: false
      t.decimal :time_unix_nano, precision: 20, scale: 0, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :payload_digest, limit: 64, null: false
      t.datetime :first_received_at, null: false
      t.index [ :series_id, :start_time_unix_nano, :time_unix_nano ], unique: true, name: "measurements_points_identity"
      t.index [ :series_id, :time_unix_nano, :id ], name: "measurements_points_order"
      t.index [ :project_id, :first_received_at ], name: "measurements_points_retention"
    end
    add_foreign_key :measurements_points, :measurements_series, column: [ :series_id, :project_id ],
                    primary_key: [ :id, :project_id ], on_delete: :cascade, name: "measurements_points_tenant_identity"
    add_check_constraint :measurements_points, "start_time_unix_nano >= 0 AND time_unix_nano > 0 AND start_time_unix_nano <= time_unix_nano AND time_unix_nano <= 18446744073709551615", name: "measurements_points_valid_time"
    add_column :settings_global, :measurements_retention_days, :integer, null: false, default: 14
    add_check_constraint :settings_global, "measurements_retention_days BETWEEN 1 AND 365", name: "settings_valid_measurement_retention"
  end
end
