class CreateSecretsPersonalVariables < ActiveRecord::Migration[8.1]
  def change
    create_table :secrets_personal_variables, id: :uuid do |t|
      t.timestamps

      # L'account È la radice di tenancy E l'unico attore del vault personale → cascade (come Todos::List),
      # nessuna colonna actor/created_by separata (account_id È l'attore).
      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }
      # Scope per-organizzazione (identico a Todos::List): un set di secret per [account, org].
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }

      # Nome UPPER_SNAKE (^[A-Z_][A-Z0-9_]*$). Nessun ban prefisso GITHUB_ (il personale non si sincronizza).
      t.string :name, null: false
      # Valore cifrato at-rest via ActiveRecord::Encryption (encrypts :value, non-deterministico).
      # text: il ciphertext + metadata è più lungo del plaintext.
      t.text :value, null: false
      t.text :description

      # Un secret per [account, organization, nome] (funge anche da index di listing).
      t.index %i[account_id organization_id name], unique: true,
              name: "index_secrets_personal_variables_on_account_org_name"
    end
  end
end
