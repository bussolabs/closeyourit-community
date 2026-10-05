class CreateServersContainerSamples < ActiveRecord::Migration[8.1]
  def change
    # Serie per-container tipizzata (chart drill-down con un WHERE). Retention corta (7 giorni):
    # il volume è ~container×1440/g per host.
    create_table :servers_container_samples, id: :uuid do |t|
      t.datetime :created_at, null: false

      t.references :host, type: :uuid, null: false,
                   foreign_key: { to_table: :servers_hosts, on_delete: :cascade }
      t.datetime :recorded_at, null: false

      t.string :name, null: false
      t.string :image
      t.string :status
      t.integer :health

      t.decimal :cpu_pct, precision: 5, scale: 2
      t.bigint :mem_bytes
      t.bigint :net_sent_bytes
      t.bigint :net_recv_bytes

      t.index %i[host_id name recorded_at]
      t.index %i[host_id recorded_at]
      t.index :recorded_at
    end
  end
end
