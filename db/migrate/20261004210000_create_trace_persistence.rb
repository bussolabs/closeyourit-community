# frozen_string_literal: true

class CreateTracePersistence < ActiveRecord::Migration[8.1]
  def change
    create_table :traces, id: :uuid do |t|
      t.timestamps
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects, on_delete: :cascade }
      t.string :trace_id, limit: 32, null: false
      t.datetime :first_received_at, null: false
      t.datetime :last_received_at, null: false
      t.bigint :retained_spans_count, null: false, default: 0
      t.bigint :expired_spans_count, null: false, default: 0
      t.index [ :project_id, :trace_id ], unique: true
      t.index [ :id, :project_id, :trace_id ], unique: true, name: "traces_tenant_identity"
      t.index [ :project_id, :last_received_at, :id ], name: "traces_project_arrival"
    end
    add_check_constraint :traces, "trace_id ~ '^[0-9a-f]{32}$' AND trace_id <> repeat('0', 32)", name: "traces_valid_identifier"
    add_check_constraint :traces, "retained_spans_count >= 0 AND expired_spans_count >= 0", name: "traces_valid_counts"

    create_table :traces_spans, id: :uuid do |t|
      t.timestamps
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects, on_delete: :cascade }
      t.uuid :trace_record_id, null: false
      t.string :trace_id, limit: 32, null: false
      t.string :span_id, limit: 16, null: false
      t.string :parent_span_id, limit: 16
      t.string :name, null: false
      t.integer :kind, null: false, default: 0
      t.integer :status_code, null: false, default: 0
      t.string :service_name
      t.decimal :start_time_unix_nano, precision: 20, scale: 0, null: false
      t.decimal :end_time_unix_nano, precision: 20, scale: 0, null: false
      t.datetime :started_at, null: false
      t.datetime :ended_at, null: false
      t.datetime :first_received_at, null: false
      t.jsonb :resource, null: false, default: {}
      t.jsonb :instrumentation_scope, null: false, default: {}
      t.string :resource_schema_url
      t.string :scope_schema_url
      t.jsonb :payload, null: false, default: {}
      t.string :payload_digest, limit: 64, null: false
      t.index [ :project_id, :trace_id, :span_id ], unique: true, name: "traces_spans_identity"
      t.index [ :project_id, :trace_id, :start_time_unix_nano, :span_id ], name: "traces_spans_order"
      t.index [ :project_id, :first_received_at ], name: "traces_spans_retention"
      t.index [ :trace_record_id, :parent_span_id ], name: "traces_spans_parent"
    end
    add_foreign_key :traces_spans, :traces, column: [ :trace_record_id, :project_id, :trace_id ],
                    primary_key: [ :id, :project_id, :trace_id ], on_delete: :cascade, name: "traces_spans_tenant_identity"
    add_check_constraint :traces_spans, "span_id ~ '^[0-9a-f]{16}$' AND span_id <> repeat('0', 16)", name: "traces_spans_valid_identifier"
    add_check_constraint :traces_spans, "parent_span_id IS NULL OR (parent_span_id ~ '^[0-9a-f]{16}$' AND parent_span_id <> repeat('0', 16) AND parent_span_id <> span_id)", name: "traces_spans_valid_parent"
    add_check_constraint :traces_spans, "start_time_unix_nano > 0 AND end_time_unix_nano >= start_time_unix_nano AND end_time_unix_nano <= 18446744073709551615", name: "traces_spans_valid_time"
    add_column :settings_global, :traces_retention_days, :integer, null: false, default: 14
    add_check_constraint :settings_global, "traces_retention_days BETWEEN 1 AND 365", name: "settings_valid_trace_retention"
  end
end
