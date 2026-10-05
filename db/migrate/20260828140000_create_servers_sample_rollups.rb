# frozen_string_literal: true

# CYRA-679 — la storia oltre la retention raw (30g): prima del prune i campioni in scadenza vengono
# ridotti a medie orarie, così una baseline lunga esiste (previsione disco, confronti stagionali)
# senza tenere un raw al minuto per un anno. Nessun rollup dei jsonb: solo hot column.
class CreateServersSampleRollups < ActiveRecord::Migration[8.1]
  def change
    create_table :servers_sample_rollups, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :host_id, null: false
      t.uuid :organization_id, null: false
      t.datetime :bucket_at, null: false
      t.integer :samples_count, null: false, default: 0
      t.decimal :cpu_pct, precision: 5, scale: 2
      t.decimal :mem_pct, precision: 5, scale: 2
      t.decimal :disk_pct, precision: 5, scale: 2
      t.decimal :data_volume_disk_pct, precision: 5, scale: 2
      t.decimal :inode_pct, precision: 5, scale: 2
      t.float :temp_max
      t.integer :db_connections_max
      t.bigint :net_sent_bytes
      t.bigint :net_recv_bytes
      t.datetime :created_at, null: false

      t.index %i[host_id bucket_at], unique: true
      t.index %i[organization_id bucket_at]
    end
    add_foreign_key :servers_sample_rollups, :servers_hosts, column: :host_id
  end
end
