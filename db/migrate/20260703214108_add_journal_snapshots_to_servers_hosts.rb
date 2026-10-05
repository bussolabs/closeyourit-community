class AddJournalSnapshotsToServersHosts < ActiveRecord::Migration[8.1]
  def change
    # Snapshot journald (ultime ~50 righe journalctl -u <unit>) per le unit systemd FAILED, keyed
    # per nome wire della unit (== campo `n` di systemd_services). Stato corrente, non storia:
    # rimpiazzato al re-fail e rimosso quando la unit esce da failed (come failed_services/smart_data).
    add_column :servers_hosts, :journal_snapshots, :jsonb, null: false, default: {}
  end
end
