# frozen_string_literal: true

# Indice composito [project_id, environment] su logs_entries: rende il DISTINCT environment del
# dropdown (Member::Monitoring::LogEntriesController#index) un index-only scan invece di un seq-scan
# sull'intero stream visibile. logs_entries è la tabella più grande dello stack (stream append-only,
# decine di milioni di righe): senza indice il dropdown ri-scansionava tutta la storia a ogni
# apertura/paginazione/filtro, con latenza costante e carico DB crescente sotto più utenti (CYRA-59).
#
# CONCURRENTLY (+ disable_ddl_transaction!) per non bloccare le scritture di ingest durante la
# creazione dell'indice su una tabella già enorme in produzione.
class AddEnvironmentIndexToLogsEntries < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_logs_entries_on_project_id_and_environment"

  def up
    # Un CREATE INDEX CONCURRENTLY interrotto lascia un indice INVALID con questo nome: un semplice
    # if_not_exists lo scambierebbe per valido e salterebbe la creazione. Rimuoverne un eventuale
    # residuo (concurrently, no-op se assente) rende la migration ri-eseguibile dopo un fallimento.
    remove_index :logs_entries, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
    add_index :logs_entries, %i[project_id environment], name: INDEX_NAME, algorithm: :concurrently
  end

  def down
    remove_index :logs_entries, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
