class CreateSecretsEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :secrets_events, id: :uuid do |t|
      t.timestamps

      # Chi ha compiuto l'azione (nil = sistema, es. il sync in background). Nullify: l'evento sopravvive.
      t.references :actor, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }, null: true
      t.references :organization, type: :uuid, null: false, foreign_key: true
      t.references :project, type: :uuid, null: false, foreign_key: true
      # Ambiente del secret (set/deleted) o del bundle (read/imported/synced); nil se non pertinente.
      t.references :environment, type: :uuid, null: true, foreign_key: { to_table: :types_environments }

      t.string :action, null: false      # read / set / deleted / imported / synced
      t.string :name                     # nome del secret (set/deleted); nil per read/imported/synced (bundle-level)
      t.jsonb  :metadata, null: false, default: {} # es. { "count" => 5 } (read/imported) o { "pushed" => 2 } (synced)

      t.index %i[project_id created_at]  # workhorse della vista audit
    end
  end
end
