# frozen_string_literal: true

# CYRA-181 — Observability PostgreSQL: hot columns del campione per chart/alert (pattern ibrido di
# Servers::Sample, tipizzato per le serie + jsonb per il dettaglio). Tutte NULLABILI: un host senza
# database non manda il blocco `database` e queste colonne restano NULL (nessun pannello, nessun alert).
# Il dettaglio (per-stato, per-database, top-tabelle, replicas, versione, engine, max) vive nel
# `payload` jsonb già esistente del campione.
class AddDatabaseColumnsToServersSamples < ActiveRecord::Migration[8.1]
  def change
    add_column :servers_samples, :db_up, :boolean
    add_column :servers_samples, :db_connections, :integer
    add_column :servers_samples, :db_replication_lag_seconds, :float
  end
end
