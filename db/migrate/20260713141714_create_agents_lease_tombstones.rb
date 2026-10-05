# frozen_string_literal: true

class CreateAgentsLeaseTombstones < ActiveRecord::Migration[8.1]
  def change
    create_table :agents_leases_tombstones, id: :uuid do |t|
      t.timestamps

      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :ticket, type: :uuid, null: false, index: false,
                            foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.references :host, type: :uuid, null: false,
                          foreign_key: { to_table: :agents_hosts, on_delete: :cascade }
      t.string :run_id, null: false
      t.datetime :released_at, null: false

      t.index %i[ticket_id host_id run_id], unique: true, name: "index_agents_lease_tombstones_idempotency"
    end
  end
end
