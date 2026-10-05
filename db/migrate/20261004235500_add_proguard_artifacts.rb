class AddProguardArtifacts < ActiveRecord::Migration[8.1]
  def change
    create_table :artifacts_proguard_maps, id: :uuid do |t|
      t.timestamps
      t.references :created_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects, on_delete: :cascade }
      t.uuid :blob_id, null: false
      t.string :release, null: false
      t.string :dist
      t.string :debug_id, limit: 36, null: false
      t.string :identity_sha256, limit: 64, null: false
      t.datetime :unreferenced_since
      t.index [ :project_id, :identity_sha256 ], unique: true, name: "artifacts_proguard_map_identity"
      t.index [ :project_id, :release ]
      t.index [ :id, :project_id ], unique: true
      t.index :blob_id, unique: true
    end
    add_foreign_key :artifacts_proguard_maps, :artifacts_blobs, column: [ :blob_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :restrict
    change_column_null :artifacts_references, :source_map_id, true
    add_column :artifacts_references, :proguard_map_id, :uuid
    add_index :artifacts_references, [ :proguard_map_id, :symbolication_id ], unique: true, name: "artifacts_unique_proguard_reference"
    add_check_constraint :artifacts_references, "(source_map_id IS NULL) <> (proguard_map_id IS NULL)", name: "artifacts_reference_one_kind"
    add_foreign_key :artifacts_references, :artifacts_proguard_maps, column: [ :proguard_map_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :cascade
  end
end
