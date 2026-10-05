# frozen_string_literal: true

# CYRA-348 — errori e prestazioni raggruppano le occorrenze uguali; i log no, e su ventimila righe il
# volume smetteva di dire qualcosa: metà delle prime righe erano lo stesso messaggio. L'impronta è la
# chiave di quel raggruppamento, calcolata all'ingresso — raggrupparle a runtime su decine di migliaia
# di righe costerebbe a ogni caricamento.
class AddFingerprintToLogsEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :logs_entries, :fingerprint, :string

    # L'indice serve alla vista raggruppata (GROUP BY per progetto) e al drill-down a una sola
    # impronta. `where` esclude le righe già in conservazione, che l'impronta non ce l'hanno.
    add_index :logs_entries, %i[project_id fingerprint],
              where: "fingerprint IS NOT NULL",
              name: "index_logs_entries_on_project_id_and_fingerprint"
  end
end
