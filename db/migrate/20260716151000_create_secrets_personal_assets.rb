# frozen_string_literal: true

# File segreti PERSONALI (CYRA-133): gemello per-utente di secrets_assets, scoped a [account, organization].
# FLAT: niente environment/project/delegation (il vault personale è possesso individuale). L'account è la
# radice di tenancy E l'unico attore → nessun created_by, cascade su account/org. Additiva: solo CREATE TABLE.
class CreateSecretsPersonalAssets < ActiveRecord::Migration[8.1]
  def change
    create_table :secrets_personal_assets, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :organization, null: false, type: :uuid, foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.string :name, null: false
      t.string :asset_type, null: false
      t.text :description
      t.datetime :archived_at
      t.timestamps
    end
    add_index :secrets_personal_assets, %i[account_id organization_id name],
              unique: true, name: "index_personal_secret_assets_scope_name"
  end
end
