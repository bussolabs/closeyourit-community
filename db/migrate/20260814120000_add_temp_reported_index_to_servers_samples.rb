# frozen_string_literal: true

# CYRA-465 — la colonna, il grafico e l'evento di avviso della temperatura spariscono quando nessun
# campione la riporta (su VM Hetzner i sensori non sono esposti, quindi l'assenza è strutturale). Il
# flag org-level è un EXISTS su servers_samples WHERE temp_max IS NOT NULL: senza indice, nel caso
# NORMALE (nessuno la espone) è un seq-scan dell'intera storia dei campioni a OGNI apertura dell'elenco
# e del form regole. L'indice parziale è minuscolo — solo le righe con un sensore letto, oggi zero — e
# rende l'EXISTS immediato in entrambi i casi.
#
# CONCURRENTLY (+ disable_ddl_transaction!) per non bloccare l'ingest dei campioni durante la creazione
# dell'indice sulla tabella già popolata in produzione.
class AddTempReportedIndexToServersSamples < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_servers_samples_temp_reported"

  def up
    # Un CREATE INDEX CONCURRENTLY interrotto lascia un indice INVALID con questo nome: rimuovere un
    # eventuale residuo (concurrently, no-op se assente) rende la migration ri-eseguibile.
    remove_index :servers_samples, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
    add_index :servers_samples, :organization_id, where: "temp_max IS NOT NULL",
              name: INDEX_NAME, algorithm: :concurrently
  end

  def down
    remove_index :servers_samples, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
