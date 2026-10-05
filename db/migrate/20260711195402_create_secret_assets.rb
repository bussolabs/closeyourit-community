class CreateSecretAssets < ActiveRecord::Migration[8.1]
  def change
    create_table :secrets_assets, id: :uuid do |t|
      t.references :organization, null: false, type: :uuid, foreign_key: { to_table: :organizations }
      t.references :project, null: true, type: :uuid, foreign_key: { to_table: :projects }
      t.references :environment, null: true, type: :uuid, foreign_key: { to_table: :types_environments }
      t.references :created_by, null: true, type: :uuid, foreign_key: { to_table: :accounts }
      t.string :name, null: false
      t.string :asset_type, null: false
      t.text :description
      t.datetime :archived_at
      t.timestamps
    end
    add_index :secrets_assets, %i[organization_id project_id environment_id name],
              unique: true, nulls_not_distinct: true, name: "index_secret_assets_scope_name"

    create_table :secrets_asset_versions, id: :uuid do |t|
      t.references :asset, null: false, type: :uuid, foreign_key: { to_table: :secrets_assets, on_delete: :cascade }
      t.references :created_by, null: true, type: :uuid, foreign_key: { to_table: :accounts }
      t.integer :number, null: false
      t.string :original_filename, null: false
      t.string :content_type, null: false
      t.bigint :byte_size, null: false
      t.text :wrapped_key, null: false
      t.string :key_iv, null: false
      t.string :key_tag, null: false
      t.string :payload_iv, null: false
      t.string :payload_tag, null: false
      t.string :fingerprint, null: false
      t.timestamps
    end
    add_index :secrets_asset_versions, %i[asset_id number], unique: true

    create_table :secrets_asset_delegations, id: :uuid do |t|
      t.references :asset, null: false, type: :uuid, foreign_key: { to_table: :secrets_assets, on_delete: :cascade }
      t.references :project, null: false, type: :uuid, foreign_key: { to_table: :projects, on_delete: :cascade }
      t.references :created_by, null: true, type: :uuid, foreign_key: { to_table: :accounts }
      t.timestamps
    end
    add_index :secrets_asset_delegations, %i[asset_id project_id], unique: true

    create_table :secrets_asset_events, id: :uuid do |t|
      t.references :organization, null: false, type: :uuid, foreign_key: { to_table: :organizations }
      t.references :asset, null: true, type: :uuid, foreign_key: { to_table: :secrets_assets, on_delete: :nullify }
      t.references :project, null: true, type: :uuid, foreign_key: { to_table: :projects }
      t.references :environment, null: true, type: :uuid, foreign_key: { to_table: :types_environments }
      t.references :actor, null: true, type: :uuid, foreign_key: { to_table: :accounts }
      t.string :action, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :secrets_asset_events, %i[organization_id created_at]
  end
end
