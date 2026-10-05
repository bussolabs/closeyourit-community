class AddKindToTicketingTickets < ActiveRecord::Migration[8.1]
  def change
    # 0 = bug → backfill atomico: tutti i ticket esistenti sono bug.
    add_column :ticketing_tickets, :kind, :integer, null: false, default: 0
  end
end
