class RemoveCreatedByFromTicketingTickets < ActiveRecord::Migration[8.1]
  def change
    # reporter è l'attore di creazione del ticket (obbligatorio + membro dell'org):
    # created_by era ridondante e introduceva un path Account fuori dal gate tenant.
    remove_reference :ticketing_tickets, :created_by, type: :uuid, null: true,
                     foreign_key: { to_table: :accounts }
  end
end
