# frozen_string_literal: true

class CreateCrashReports < ActiveRecord::Migration[8.1]
  def change
    create_table :crashes_reports, id: :uuid do |t|
      t.timestamps
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects, on_delete: :cascade }
      t.string :event_id, null: false, limit: 32
      t.string :release
      t.string :environment
      t.jsonb :manifest, null: false, default: {}
    end
    add_index :crashes_reports, [ :project_id, :event_id ], unique: true
    add_index :crashes_reports, [ :id, :project_id ], unique: true
    add_index :crashes_reports, :created_at
    add_check_constraint :crashes_reports, "event_id ~ '^[0-9a-f]{32}$'", name: "crashes_valid_event_id"

    # Lifecycle rows deliberately survive tenant cascades, carrying only opaque storage metadata.
    create_table :crashes_blobs, id: :uuid do |t|
      t.timestamps
      t.uuid :project_id, null: false
      t.string :key, null: false
      t.string :service_name, null: false
      t.bigint :byte_size, null: false
      t.string :sha256, null: false, limit: 64
      t.datetime :reserved_until, null: false
    end
    add_index :crashes_blobs, :key, unique: true
    add_index :crashes_blobs, :project_id
    add_index :crashes_blobs, :reserved_until
    add_check_constraint :crashes_blobs, "byte_size BETWEEN 0 AND 10485760", name: "crashes_valid_blob_size"
    add_check_constraint :crashes_blobs, "sha256 ~ '^[0-9a-f]{64}$'", name: "crashes_valid_blob_digest"

    create_table :crashes_attachments, id: :uuid do |t|
      t.timestamps
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects, on_delete: :cascade }
      t.uuid :report_id, null: false
      t.references :blob, type: :uuid, null: false, foreign_key: { to_table: :crashes_blobs }
      t.string :filename, null: false
      t.string :kind, null: false
    end
    add_foreign_key :crashes_attachments, :crashes_reports, column: [ :report_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :cascade
    add_index :crashes_attachments, :blob_id, unique: true, name: "crashes_unique_blob_attachment"
    add_index :crashes_attachments, [ :report_id, :filename ], unique: true
    add_check_constraint :crashes_attachments, "kind IN ('text','report')", name: "crashes_valid_attachment_kind"
    add_column :settings_global, :crashes_retention_days, :integer, null: false, default: 30
    add_check_constraint :settings_global, "crashes_retention_days BETWEEN 1 AND 365", name: "settings_crashes_retention_range"
  end
end
