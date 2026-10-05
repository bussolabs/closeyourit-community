# frozen_string_literal: true

# CYRA-167: le idee entrano nella ricerca per significato e nel suggerimento dei doppioni, come già
# ticket, gruppi d'errore e pagine di conoscenza. Stesse quattro colonne infrastrutturali delle altre
# tabelle embeddate — vettore, checksum di staleness, istante dell'ultimo calcolo e versione del
# modello (CYRA-168: la ricerca confronta SOLO righe della versione corrente).
#
# Puramente additiva: tutte nullable, nessun backfill nel DDL. Le idee esistenti restano senza vettore
# finché Ideas::BackfillEmbeddingsJob non le indicizza (idempotente, gira anche in recurring.yml).
class AddEmbeddingToIdeasIdeas < ActiveRecord::Migration[8.1]
  def change
    change_table :ideas_ideas, bulk: true do |t|
      t.datetime :embedded_at
      t.string   :embedding_checksum
      t.string   :embedding_version
      t.column   :embedding, :vector, limit: 1024
    end

    # HNSW come sulle altre tabelle embeddate: i filtri di visibilità riducono già molto lo scope,
    # l'indice serve quando la bacheca di un'org cresce.
    add_index :ideas_ideas, :embedding, using: :hnsw, opclass: :vector_cosine_ops
    # Filtro d'uguaglianza `embedding_version = ?` anteposto a ogni nearest_neighbors.
    add_index :ideas_ideas, :embedding_version
  end
end
