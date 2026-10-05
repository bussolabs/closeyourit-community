class CreateSecretsPersonalEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :secrets_personal_events, id: :uuid do |t|
      t.timestamps

      # L'account È l'attore (radice di tenancy): cascade, nessuna colonna actor separata.
      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }

      t.string :action, null: false      # read / set / deleted / imported (no synced: il personale non si sincronizza)
      t.string :name                     # nome del secret (set/deleted); nil per read/imported (bundle-level)
      t.jsonb  :metadata, null: false, default: {} # es. { "count" => 5 } (read/imported)

      t.index %i[account_id organization_id created_at] # workhorse della vista audit
    end
  end
end
