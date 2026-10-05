# frozen_string_literal: true

# Book = collezione ordinata di pagine KB dello stesso progetto (vista Outline: indice a sinistra,
# contenuto a destra). Project-scoped come le pagine. Il legame pagina→book è una FK diretta
# (una pagina sta al più in un book); l'ordine nel TOC vive su knowledge_pages.position.
class CreateKnowledgeBooks < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_books, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, foreign_key: { to_table: :accounts }, null: false

      t.references :project, type: :uuid, foreign_key: { to_table: :projects }, null: false
      t.string :title, null: false
      t.text :description
    end

    # Legame pagina→book: nullify alla cancellazione del book (le pagine sopravvivono, tornano libere).
    add_reference :knowledge_pages, :book, type: :uuid, null: true, index: true,
                  foreign_key: { to_table: :knowledge_books, on_delete: :nullify }
    # Ordine della pagina nel TOC del book (significativo solo quando book_id è presente).
    add_column :knowledge_pages, :position, :integer, null: false, default: 0
  end
end
