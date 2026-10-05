# frozen_string_literal: true

class AddHeartbeatAtToDatasetsTrainings < ActiveRecord::Migration[8.1]
  # CYRA-791 — segno di vita dell'esecuzione in corso. Senza, un addestramento ucciso con il processo
  # (deploy interrotto, worker terminato) resta `running` per sempre e la guardia anti-doppione blocca
  # ogni avvio successivo su quel dataset. Nullable: i pending non hanno ancora battuto e i training
  # già chiusi non battono più — chi legge usa `COALESCE(heartbeat_at, created_at)`.
  def change
    add_column :datasets_trainings, :heartbeat_at, :datetime
  end
end
