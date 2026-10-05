# frozen_string_literal: true

# Versioni immutabili dei file segreti personali: envelope crittografico (wrapped DEK + IV/tag) speculare a
# secrets_asset_versions; il ciphertext vive su ActiveStorage (has_one_attached). NIENTE created_by (l'account
# è l'attore, come secrets_personal_versions). Additiva: solo CREATE TABLE.
class CreateSecretsPersonalAssetVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :secrets_personal_asset_versions, id: :uuid do |t|
      t.references :asset, null: false, type: :uuid,
                   foreign_key: { to_table: :secrets_personal_assets, on_delete: :cascade }
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
    add_index :secrets_personal_asset_versions, %i[asset_id number],
              unique: true, name: "index_personal_secret_asset_versions_number"
  end
end
