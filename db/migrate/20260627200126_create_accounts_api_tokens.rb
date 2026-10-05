class CreateAccountsApiTokens < ActiveRecord::Migration[8.1]
  # Token a livello UTENTE per la CLI (account-proxy): autentica COME l'account, l'autorizzazione di
  # ogni azione passa per Authorization::Resolver. Distinto dai Projects::Token (ingest macchina,
  # prefisso "cyi_") dal prefisso "cyi_u_". In DB solo il digest SHA-256 del segreto (mostrato UNA volta).
  def change
    create_table :accounts_api_tokens, id: :uuid do |t|
      t.timestamps

      # account_id = proprietario umano del token (account-proxy) → niente created_by separato.
      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }

      t.string   :name,         null: false   # etichetta umana ("MacBook · oclif")
      t.string   :token_digest, null: false   # SHA-256 del segreto bearer (lookup O(1), non bcrypt)
      t.string   :token_prefix, null: false   # "cyi_u_" + 8 char in chiaro per display
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.datetime :expires_at                  # nullable: in v1 nessuna scadenza di default

      t.index :token_digest, unique: true
      t.index [ :account_id, :revoked_at ]
      t.index [ :organization_id, :revoked_at ]
    end
  end
end
