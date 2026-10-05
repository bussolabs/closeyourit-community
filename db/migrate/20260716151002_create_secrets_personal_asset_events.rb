# frozen_string_literal: true

# Audit append-only dei file segreti personali (uploaded/downloaded/rolled_back/archived/purged), scoped a
# [account, organization]. asset_id nullify così l'audit sopravvive al purge del file. Additiva: solo CREATE TABLE.
class CreateSecretsPersonalAssetEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :secrets_personal_asset_events, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :organization, null: false, type: :uuid, foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.references :asset, null: true, type: :uuid,
                   foreign_key: { to_table: :secrets_personal_assets, on_delete: :nullify }
      t.string :action, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :secrets_personal_asset_events, %i[account_id organization_id created_at],
              name: "index_personal_secret_asset_events_scope"
  end
end
