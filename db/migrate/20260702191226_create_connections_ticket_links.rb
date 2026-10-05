# frozen_string_literal: true

class CreateConnectionsTicketLinks < ActiveRecord::Migration[8.1]
  def change
    # Relazione ticket↔ticket (duplicato/correlato) creata dal flusso "crea e collega"
    # del gate duplicati. Direzionale in scrittura (ticket = nuovo, related = preesistente)
    # ma mostrata su entrambe le show (scope involving).
    create_table :connections_ticket_links, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, foreign_key: { to_table: :accounts }, null: false

      t.references :ticket, type: :uuid, foreign_key: { to_table: :ticketing_tickets }, null: false
      t.references :related, type: :uuid, foreign_key: { to_table: :ticketing_tickets }, null: false
      t.integer :kind, null: false, default: 0

      t.index %i[ticket_id related_id], unique: true
    end
  end
end
