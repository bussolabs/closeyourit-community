class AddNativeSymbolArtifacts < ActiveRecord::Migration[8.1]
  def change
    create_table :artifacts_native_symbols, id: :uuid do |t|
      t.timestamps
      t.references :created_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects, on_delete: :cascade }
      t.uuid :blob_id, null: false
      t.string :format, null: false, limit: 16
      t.string :architecture, null: false, limit: 32
      t.string :debug_id, null: false, limit: 45
      t.string :code_id, limit: 256
      t.string :identity_sha256, limit: 64, null: false
      t.datetime :unreferenced_since
      t.index [ :project_id, :identity_sha256 ], unique: true, name: "artifacts_native_symbol_identity"
      t.index [ :project_id, :debug_id ]
      t.index [ :id, :project_id ], unique: true
      t.index :blob_id, unique: true
    end
    add_foreign_key :artifacts_native_symbols, :artifacts_blobs, column: [ :blob_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :restrict
    add_column :artifacts_references, :native_symbol_id, :uuid
    add_index :artifacts_references, [ :native_symbol_id, :symbolication_id ], unique: true, name: "artifacts_unique_native_reference"
    remove_check_constraint :artifacts_references, "(source_map_id IS NULL) <> (proguard_map_id IS NULL)", name: "artifacts_reference_one_kind"
    add_check_constraint :artifacts_references, "num_nonnulls(source_map_id, proguard_map_id, native_symbol_id) = 1", name: "artifacts_reference_one_kind"
    add_foreign_key :artifacts_references, :artifacts_native_symbols, column: [ :native_symbol_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :cascade
    add_column :errors_symbolications, :crash_report_id, :uuid
    add_column :errors_symbolications, :manifest_sha256, :string, limit: 64
    add_index :errors_symbolications, :crash_report_id
    add_foreign_key :errors_symbolications, :crashes_reports, column: [ :crash_report_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :cascade
  end
end
