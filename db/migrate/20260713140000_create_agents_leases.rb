# frozen_string_literal: true

class CreateAgentsLeases < ActiveRecord::Migration[8.1]
  def change
    create_table :agents_leases, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :ticket, type: :uuid, null: false, index: false,
                            foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.references :host, type: :uuid, null: false,
                          foreign_key: { to_table: :agents_hosts, on_delete: :cascade }
      t.string :run_id, null: false
      t.string :agent, null: false
      t.datetime :expires_at, null: false
      t.timestamps

      t.index :ticket_id, unique: true, name: "index_agents_leases_unique_ticket"
      t.index %i[organization_id expires_at]
      t.index %i[host_id expires_at]
    end
  end
end
