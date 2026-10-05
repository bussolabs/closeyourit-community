class CreateServersSamples < ActiveRecord::Migration[8.1]
  def change
    # Riga immutabile (niente updated_at, come logs_entries): un campione di sistema al minuto per host.
    create_table :servers_samples, id: :uuid do |t|
      t.datetime :created_at, null: false

      t.references :host, type: :uuid, null: false,
                   foreign_key: { to_table: :servers_hosts, on_delete: :cascade }
      # Org denormalizzata: tenancy nelle query di prune/visibilità senza join su servers_hosts.
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :recorded_at, null: false

      # Hot columns tipizzate: alimentano chart (date_bin) e fleet senza aprire il jsonb.
      t.decimal :cpu_pct, precision: 5, scale: 2, null: false, default: 0
      t.decimal :mem_pct, precision: 5, scale: 2
      t.decimal :disk_pct, precision: 5, scale: 2
      t.decimal :gpu_pct, precision: 5, scale: 2
      t.decimal :load_1, precision: 8, scale: 2
      t.decimal :load_5, precision: 8, scale: 2
      t.decimal :load_15, precision: 8, scale: 2
      t.bigint :net_sent_bytes
      t.bigint :net_recv_bytes
      t.bigint :disk_read_bytes
      t.bigint :disk_write_bytes
      t.bigint :uptime_seconds
      t.decimal :temp_max, precision: 6, scale: 2
      t.integer :services_total
      t.integer :services_failed

      # Dettaglio normalizzato (temps per sensore, extra_fs, gpu, cpu_breakdown, per_nic, battery,
      # swap, mem in valori assoluti). NIENTE systemd/SMART qui: stato corrente su servers_hosts.
      t.jsonb :payload, null: false, default: {}

      # Idempotenza sui retry dell'agent: stesso (host, recorded_at) → insert no-op.
      t.index %i[host_id recorded_at], unique: true
      t.index :recorded_at
    end
  end
end
