class CreateServersJournalEntries < ActiveRecord::Migration[8.1]
  def change
    # Riga immutabile (niente updated_at, come logs_entries/servers_samples): una riga journald
    # (priority <= err/crit) push-ata dall'agent. Stream append-only, retention 48h.
    create_table :servers_journal_entries, id: :uuid do |t|
      t.datetime :created_at, null: false

      t.references :host, type: :uuid, null: false,
                   foreign_key: { to_table: :servers_hosts, on_delete: :cascade }
      # Org denormalizzata: tenancy nel prune/visibilità senza join su servers_hosts.
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }

      # Timestamp della riga journald (__REALTIME_TIMESTAMP), non del push.
      t.datetime :occurred_at, null: false
      # PRIORITY syslog 0..7 (emerg..debug); qui arrivano solo <= 3 (err/crit/alert/emerg).
      t.integer :priority, null: false
      # _SYSTEMD_UNIT || SYSLOG_IDENTIFIER || "kernel".
      t.string :unit
      t.text :message, null: false
      # __CURSOR journald: idempotenza sui retry dell'agent (il cursore client avanza solo a push OK).
      t.string :cursor, null: false

      t.index %i[host_id cursor], unique: true
      t.index %i[host_id occurred_at]
      # Prune per finestra temporale (retention 48h) senza toccare host_id.
      t.index :occurred_at
    end
  end
end
