class CreateServersHosts < ActiveRecord::Migration[8.1]
  def change
    create_table :servers_hosts, id: :uuid do |t|
      t.timestamps

      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }

      # Identità: fingerprint stabile calcolato dall'agent (sha256(machine-id||hostname+cpu)[:24]).
      # È la chiave di auto-registrazione: stesso fingerprint → stesso host, anche se rinominato.
      t.string :fingerprint, null: false
      t.string :name, null: false
      t.string :hostname
      t.integer :status, null: false, default: 0
      t.datetime :last_seen_at
      t.datetime :revoked_at
      t.string :agent_version

      # Statici riportati dall'agent a ogni push (cambiano solo a upgrade macchina/OS).
      t.string :os_name
      t.string :arch
      t.string :kernel
      t.string :cpu_model
      t.integer :cores
      t.integer :threads
      t.bigint :memory_total_bytes

      # Snapshot ultimo campione, denormalizzato: la fleet index ordina/mostra senza lateral join
      # sull'ultimo sample (1 UPDATE/60s/host, costo trascurabile).
      t.decimal :cpu_pct, precision: 5, scale: 2
      t.decimal :mem_pct, precision: 5, scale: 2
      t.decimal :disk_pct, precision: 5, scale: 2
      t.decimal :temp_max, precision: 6, scale: 2
      t.decimal :load_1, precision: 8, scale: 2
      t.decimal :load_5, precision: 8, scale: 2
      t.decimal :load_15, precision: 8, scale: 2
      t.bigint :uptime_seconds
      t.integer :services_total
      t.integer :services_failed
      t.integer :containers_count

      # Stato corrente non storicizzato (i sample restano snelli): lista systemd, esito SMART per
      # device, nomi dei servizi failed (per rilevare le transizioni), dettagli liberi.
      t.jsonb :systemd_services, null: false, default: []
      t.jsonb :smart_data, null: false, default: {}
      t.jsonb :failed_services, null: false, default: []
      t.jsonb :details, null: false, default: {}

      t.index %i[organization_id fingerprint], unique: true
      t.index %i[organization_id status]
      t.index %i[status last_seen_at]
    end
  end
end
