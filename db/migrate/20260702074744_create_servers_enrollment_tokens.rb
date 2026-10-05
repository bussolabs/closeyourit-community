class CreateServersEnrollmentTokens < ActiveRecord::Migration[8.1]
  def change
    # Token universale org-scoped per gli agent (stile Beszel universal token): un segreto condiviso
    # dalla flotta, mostrato UNA volta; in DB solo il digest SHA-256. Tabella dedicata (non colonna
    # su organizations) per rotazione con più token attivi + audit, pattern projects_tokens.
    create_table :servers_enrollment_tokens, id: :uuid do |t|
      t.timestamps

      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :created_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.string :name, null: false
      t.string :token_prefix, null: false
      t.string :token_digest, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.index :token_digest, unique: true
      t.index %i[organization_id name], unique: true
    end
  end
end
