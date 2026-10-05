# frozen_string_literal: true

# Grafo pagina↔pagina della knowledge base, DERIVATO dai wikilink `[[Titolo]]` scritti nel corpo
# (vedi Knowledge::Links::Sync): riscritto per intero ad ogni salvataggio della pagina sorgente.
#
# Niente `kind` e niente `created_by`: il collegamento non ha varianti né un attore proprio —
# l'autore è chi ha scritto il corpo, tracciato dalla pagina stessa e dai suoi snapshot.
# `target_title` conserva il titolo COSÌ COM'È SCRITTO nel wikilink: è la chiave che permette a
# Knowledge::Links::Render di riagganciare `[[…]]` alla riga anche dopo che la destinazione è
# stata rinominata (il collegamento è congelato per id, il testo del corpo no).
#
# Cascade su entrambi i capi: un collegamento senza una delle due pagine non significa nulla.
class CreateConnectionsPageLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :connections_page_links, id: :uuid do |t|
      t.references :page, null: false, type: :uuid,
                          foreign_key: { to_table: :knowledge_pages, on_delete: :cascade }
      t.references :related, null: false, type: :uuid,
                             foreign_key: { to_table: :knowledge_pages, on_delete: :cascade }
      t.string :target_title, null: false
      t.timestamps
    end

    add_index :connections_page_links, %i[page_id related_id], unique: true
  end
end
