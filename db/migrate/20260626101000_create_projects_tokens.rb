class CreateProjectsTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :projects_tokens, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts }

      t.references :project, type: :uuid, null: false, foreign_key: true

      t.string :name, null: false                     # etichetta umana ("Production SDK", "CI")
      t.string :token_digest, null: false             # SHA-256 del segreto bearer (lookup O(1), non bcrypt)
      t.string :token_prefix, null: false             # primi char in chiaro per display ("cyi_a1b2c3d4")
      t.string :public_key, null: false               # DSN public key Sentry (32 hex) — non segreto, viaggia negli SDK
      t.jsonb  :scopes, null: false, default: [ "ingest" ]
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.index :token_digest, unique: true
      t.index :public_key, unique: true
      t.index [ :project_id, :revoked_at ]
    end
  end
end
