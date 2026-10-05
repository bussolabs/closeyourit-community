class AddWeightToTicketingTickets < ActiveRecord::Migration[8.1]
  def change
    # Peso/punti opzionale (story points / stima sforzo). nil = non stimato (conta 1 nel progress).
    add_column :ticketing_tickets, :weight, :integer
  end
end
