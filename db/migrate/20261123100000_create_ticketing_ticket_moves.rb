# frozen_string_literal: true

# CYRA-1352 — a ticket moved to another project takes a new code there; the old code keeps leading to it.
class CreateTicketingTicketMoves < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_ticket_moves, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: true
      t.references :ticket, type: :uuid, null: false, foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.references :from_project, type: :uuid, null: false, foreign_key: { to_table: :projects, on_delete: :cascade },
                                  index: false
      t.integer :from_number, null: false
      t.references :to_project, type: :uuid, null: false, foreign_key: { to_table: :projects, on_delete: :cascade }
      t.integer :to_number, null: false
      t.references :actor, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.timestamps
    end
    add_index :ticketing_ticket_moves, %i[from_project_id from_number], unique: true
  end
end
