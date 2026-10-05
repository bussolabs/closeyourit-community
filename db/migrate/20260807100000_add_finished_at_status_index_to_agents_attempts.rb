# frozen_string_literal: true

# Indice per i giri di monitoraggio degli attempt sulla finestra recente (CYRA-282): Agents::Attempts::
# DetectFailingHosts (ogni ora) e DetectStalled (ogni 15') filtrano WHERE finished_at BETWEEN … AND status
# IN (…). `agents_attempts` è audit immutabile e MAI potata: senza indice ogni giro è un seq-scan su tutta
# la storia, che cresce senza limite. `finished_at` come prima colonna serve il range della finestra (il
# filtro dominante: poche righe recenti su mesi di dati), `status` affina.
#
# CONCURRENTLY (+ disable_ddl_transaction!) per non bloccare le scritture di attempt durante la creazione
# dell'indice sulla tabella già popolata in produzione.
class AddFinishedAtStatusIndexToAgentsAttempts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "idx_agents_attempts_finished_at_status"

  def up
    # Un CREATE INDEX CONCURRENTLY interrotto lascia un indice INVALID con questo nome: rimuovere un
    # eventuale residuo (concurrently, no-op se assente) rende la migration ri-eseguibile.
    remove_index :agents_attempts, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
    add_index :agents_attempts, %i[finished_at status], name: INDEX_NAME, algorithm: :concurrently
  end

  def down
    remove_index :agents_attempts, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
