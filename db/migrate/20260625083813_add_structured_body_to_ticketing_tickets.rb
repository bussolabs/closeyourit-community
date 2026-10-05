class AddStructuredBodyToTicketingTickets < ActiveRecord::Migration[8.1]
  def change
    add_column :ticketing_tickets, :step_given, :text
    add_column :ticketing_tickets, :step_when, :text
    add_column :ticketing_tickets, :step_then, :text
    add_column :ticketing_tickets, :step_expected, :text
  end
end
