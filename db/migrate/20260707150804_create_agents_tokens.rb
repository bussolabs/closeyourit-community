class CreateAgentsTokens < ActiveRecord::Migration[8.1]
  def change
    # Token org-scoped con cui closeyourit-automator si autentica verso l'API (GET agenti / POST run).
    # Un solo segreto per la flotta, mostrato UNA volta; in DB solo il digest SHA-256. Pattern
    # identico a servers_enrollment_tokens (prefisso cyi_a_ invece di cyi_s_).
    create_table :agents_tokens, id: :uuid do |t|
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
