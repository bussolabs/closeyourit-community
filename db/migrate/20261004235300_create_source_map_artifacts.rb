# frozen_string_literal: true

class CreateSourceMapArtifacts < ActiveRecord::Migration[8.1]
  def change
    create_table :artifacts_blobs, id: :uuid do |t|
      t.timestamps
      t.uuid :project_id, null: false
      t.string :key, null: false
      t.string :service_name, null: false
      t.bigint :byte_size, null: false
      t.string :sha256, limit: 64, null: false
      t.datetime :reserved_until, null: false
      t.index :key, unique: true
      t.index :project_id
      t.index [ :id, :project_id ], unique: true
      t.check_constraint "byte_size BETWEEN 0 AND 5242880", name: "artifacts_blob_size"
    end

    create_table :artifacts_source_maps, id: :uuid do |t|
      t.timestamps
      t.references :created_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects, on_delete: :cascade }
      t.uuid :blob_id, null: false
      t.string :release, null: false
      t.string :dist
      t.text :generated_file, null: false
      t.string :debug_id, limit: 36
      t.string :identity_sha256, limit: 64, null: false
      t.datetime :unreferenced_since
      t.index [ :project_id, :identity_sha256 ], unique: true, name: "artifacts_source_map_identity"
      t.index [ :project_id, :release ]
      t.index [ :id, :project_id ], unique: true
      t.index :blob_id, unique: true
    end
    add_foreign_key :artifacts_source_maps, :artifacts_blobs, column: [ :blob_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :restrict

    create_table :errors_symbolications, id: :uuid do |t|
      t.timestamps
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects, on_delete: :cascade }
      # Event partitions can be dropped without a referencing FK blocking retention.
      t.uuid :event_id, null: false
      t.datetime :event_created_at, null: false
      t.jsonb :result, null: false, default: {}
      t.index [ :project_id, :event_id, :event_created_at ], unique: true, name: "errors_symbolication_event"
      t.index [ :id, :project_id ], unique: true
    end

    create_table :artifacts_references, id: :uuid do |t|
      t.timestamps
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects, on_delete: :cascade }
      t.uuid :source_map_id, null: false
      t.uuid :symbolication_id, null: false
      t.index [ :source_map_id, :symbolication_id ], unique: true, name: "artifacts_unique_reference"
      t.index :symbolication_id
    end
    add_foreign_key :artifacts_references, :artifacts_source_maps, column: [ :source_map_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :cascade
    add_foreign_key :artifacts_references, :errors_symbolications, column: [ :symbolication_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :cascade
    add_column :settings_global, :artifacts_retention_days, :integer, null: false, default: 30
    add_check_constraint :settings_global, "artifacts_retention_days BETWEEN 1 AND 365", name: "settings_artifacts_retention"
  end
end
