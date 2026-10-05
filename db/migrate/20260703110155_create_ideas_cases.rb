class CreateIdeasCases < ActiveRecord::Migration[8.1]
  # Case dell'idea: entità figlia ripetibile (titolo + descrizione), aggiunta una alla volta
  # sulla pagina idea come i commenti. Contenuto dell'idea → nessun created_by. Cascade con l'idea.
  def change
    create_table :ideas_cases, id: :uuid do |t|
      t.timestamps

      t.references :idea, type: :uuid, null: false, index: false,
                   foreign_key: { to_table: :ideas_ideas, on_delete: :cascade }

      t.string :title, null: false
      t.text :description
    end

    add_index :ideas_cases, [ :idea_id, :created_at ]

    add_column :ideas_ideas, :cases_count, :integer, null: false, default: 0
  end
end
