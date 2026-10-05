class CreateAnalyticsLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :analytics_links, id: :uuid do |t|
      t.timestamps

      t.references :project, null: false, foreign_key: { on_delete: :cascade }, type: :uuid

      # Slug pubblico imprevedibile = capability del link (l'accesso all'embed). password_digest
      # opzionale per protezione aggiuntiva; enabled per la revoca senza perdere lo storico.
      t.string :slug, null: false
      t.string :password_digest
      t.boolean :enabled, null: false, default: true

      t.index :slug, unique: true
    end
  end
end
