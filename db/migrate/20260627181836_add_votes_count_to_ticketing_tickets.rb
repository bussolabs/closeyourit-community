# frozen_string_literal: true

# Contatore denormalizzato dei voti sul ticket (counter_cache di Connections::TicketVote):
# la roadmap ordina per voti senza COUNT a ogni riga.
class AddVotesCountToTicketingTickets < ActiveRecord::Migration[8.1]
  def change
    add_column :ticketing_tickets, :votes_count, :integer, null: false, default: 0
  end
end
