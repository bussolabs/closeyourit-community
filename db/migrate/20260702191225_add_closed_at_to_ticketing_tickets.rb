# frozen_string_literal: true

class AddClosedAtToTicketingTickets < ActiveRecord::Migration[8.1]
  def up
    # Momento di ingresso nello status "done" (category chiusa): alimenta la finestra
    # "chiusi di recente" del gate duplicati alla creazione. Gestito dal model
    # (Ticketing::Ticket#sync_closed_at), mai dal form.
    add_column :ticketing_tickets, :closed_at, :datetime
    add_index :ticketing_tickets, :closed_at

    # Backfill dei ticket già chiusi: non esiste lo storico dell'istante di chiusura,
    # updated_at è l'approssimazione migliore disponibile (ultima mutazione del ticket).
    # category = 2 → Types::TicketStatus enum :category, done: 2.
    execute <<~SQL
      UPDATE ticketing_tickets
      SET closed_at = ticketing_tickets.updated_at
      FROM types_ticket_statuses
      WHERE types_ticket_statuses.id = ticketing_tickets.status_id
        AND types_ticket_statuses.category = 2
    SQL
  end

  def down
    remove_column :ticketing_tickets, :closed_at
  end
end
