# frozen_string_literal: true

# Indice composito [group_id, user_hash] su errors_events: rende new_user_for?
# (Errors::Ingest::Record) una index-only lookup O(log n) invece del full-scan del gruppo con il
# filtro user_hash sul heap. Un errore ricorrente accumula milioni di occorrenze con lo stesso
# group_id: senza indice, ogni nuovo evento scandiva l'intero gruppo prima dell'insert, facendo
# esplodere il lag della coda :ingest sotto burst (CYRA-50).
#
# CONCURRENTLY (+ disable_ddl_transaction!) per non bloccare le scritture di ingest durante la
# creazione dell'indice su una tabella già enorme in produzione.
class AddUserHashIndexToErrorsEvents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_errors_events_on_group_id_and_user_hash"

  def up
    # Un CREATE INDEX CONCURRENTLY interrotto lascia un indice INVALID con questo nome: un semplice
    # if_not_exists lo scambierebbe per valido e salterebbe la creazione, lasciando new_user_for?
    # senza indice utilizzabile. Rimuoverne un eventuale residuo (concurrently, no-op se assente)
    # rende la migration ri-eseguibile in sicurezza dopo un fallimento.
    remove_index :errors_events, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
    add_index :errors_events, %i[group_id user_hash], name: INDEX_NAME, algorithm: :concurrently
  end

  def down
    remove_index :errors_events, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
