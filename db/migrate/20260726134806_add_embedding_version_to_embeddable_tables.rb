# frozen_string_literal: true

# CYRA-168: colonna FILTRABILE con la versione del modello di embedding usata per ogni riga.
# Finora la versione viveva solo dentro `embedding_checksum` (digest opaco, non filtrabile in SQL):
# durante un re-embed (bump di Ai::Constants::EMBEDDING_VERSION) le righe possono avere vettori di
# versioni diverse e le query nearest-neighbors, non potendo filtrare, mescolavano distanze coseno
# prive di senso. Con questa colonna la ricerca semantica confronta SOLO righe della versione corrente.
#
# Puramente additiva e retrocompatibile: nullable, default nil, nessun backfill nel DDL (le righe
# già embeddate vengono stampate a versione corrente da Embeddings::BackfillVersionJob al deploy,
# per non tenere un lock su tabelle grandi). L'indice serve al filtro d'uguaglianza `embedding_version = ?`.
class AddEmbeddingVersionToEmbeddableTables < ActiveRecord::Migration[8.1]
  def change
    %i[errors_groups knowledge_pages ticketing_tickets].each do |table|
      add_column table, :embedding_version, :string
      add_index table, :embedding_version
    end
  end
end
