# frozen_string_literal: true

# CYRA-181 — Observability PostgreSQL: snapshot denormalizzato dell'ULTIMO blocco `database` ricevuto
# (stato corrente, non storia — come smart_data/systemd_services/journal_snapshots) + ruolo di replica
# per il badge nella fleet index. Host senza database: il blocco non arriva mai → snapshot {} e
# db_role NULL (nessun pannello, nessun badge).
class AddDatabaseSnapshotToServersHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :servers_hosts, :database_snapshot, :jsonb, null: false, default: {}
    add_column :servers_hosts, :db_role, :string
  end
end
