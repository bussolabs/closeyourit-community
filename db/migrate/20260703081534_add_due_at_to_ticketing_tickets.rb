# frozen_string_literal: true

class AddDueAtToTicketingTickets < ActiveRecord::Migration[8.1]
  def change
    # Scadenza opzionale del ticket (giorno + ora). Nullable: la maggior parte dei ticket
    # non ha una deadline. Può essere passata (ticket scaduto) o futura → nessuna validazione
    # sul model. Indicizzata perché è colonna ordinabile nella tabella index.
    add_column :ticketing_tickets, :due_at, :datetime
    add_index :ticketing_tickets, :due_at
  end
end
