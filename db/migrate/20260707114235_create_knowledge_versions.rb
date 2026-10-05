# frozen_string_literal: true

class CreateKnowledgeVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_versions, id: :uuid do |t|
      # Snapshot immutabile: solo created_at (nessun updated_at) — pattern Errors::Event/Logs::Entry.
      t.datetime :created_at, null: false

      t.references :page, type: :uuid, null: false,
                   foreign_key: { to_table: :knowledge_pages, on_delete: :cascade }
      # Autore dello snapshot: sopravvive alla cancellazione dell'account.
      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
      # organization_id denormalizzato: scoping/integrità tenant senza join sulla pagina→progetto.
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }

      t.string  :author_name                     # nome autore snapshottato (resiste alla cancellazione)
      t.integer :number, null: false             # progressivo monotòno per pagina
      t.string  :title,  null: false             # contenuto congelato
      t.text    :body,   null: false
      t.integer :kind,   null: false, default: 0 # enum come Knowledge::Page

      t.index %i[page_id number], unique: true   # numerazione monotòna per pagina
      t.index %i[page_id created_at]             # cronologia
    end
  end
end
