class CreateProjectsDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :projects_documents, id: :uuid do |t|
      t.timestamps
      # created_by → nullify alla cancellazione account (il documento sopravvive).
      t.references :created_by, type: :uuid, null: true, foreign_key: { to_table: :accounts, on_delete: :nullify }
      # Scoped al PROGETTO: la documentazione (spec, contratti, export) appartiene al singolo progetto.
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects }

      # title = nome mostrato/rinominabile, separato da blob.filename (che resta il nome originale).
      t.string :title, null: false
      t.text   :description
      # Tag liberi normalizzati (strip/downcase/uniq) — niente entità Tag: filtro via overlap &&.
      t.text   :tags, array: true, null: false, default: []

      t.index %i[project_id created_at]
      t.index :tags, using: :gin
    end
  end
end
