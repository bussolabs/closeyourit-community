# frozen_string_literal: true

# CYRA-1219 — the channel a ticket was born from and the account that typed it. Only a reference:
# deleting the account empties it, and no name or contact is copied onto the ticket.
class AddOriginAndCreatedByToTickets < ActiveRecord::Migration[8.1]
  def change
    add_column :ticketing_tickets, :origin, :string
    add_reference :ticketing_tickets, :created_by, type: :uuid, null: true, index: true,
                                                   foreign_key: { to_table: :accounts, on_delete: :nullify }
  end
end
