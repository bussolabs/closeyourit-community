# frozen_string_literal: true

# CYRA-223: l'epic diventa un contenitore vero. Un ticket può avere UN epic padre, dello stesso
# progetto, con gerarchia a un solo livello (le regole vivono in Ticketing::Ticket).
#
# on_delete: :nullify — cancellare un epic non deve portarsi via il lavoro appeso sotto: i figli
# sopravvivono orfani, esattamente come per milestone_id.
class AddParentToTicketingTickets < ActiveRecord::Migration[8.1]
  def change
    add_reference :ticketing_tickets, :parent, type: :uuid, index: true,
                  foreign_key: { to_table: :ticketing_tickets, on_delete: :nullify }
  end
end
