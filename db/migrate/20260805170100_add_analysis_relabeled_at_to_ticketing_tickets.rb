# frozen_string_literal: true

# La guardia che rende ripetibile la riscrittura delle analisi a etichette (CYRA-266).
#
# Gemella di `analysis_recomposed_at` (CYRA-260) e per la stessa ragione: un backfill che tocca 423
# ticket non finisce in un colpo solo — si ferma, lo si rilancia, e senza un timestamp ricomincerebbe
# da capo spendendo di nuovo 423 chiamate al provider per riscrivere ciò che ha appena scritto.
#
# NON serve una colonna di backup accanto: l'originale finisce nella cronologia del ticket, perché la
# riscrittura passa da Ticketing::UpdateTicket e il suo log_changes registra la coppia prima→dopo.
class AddAnalysisRelabeledAtToTicketingTickets < ActiveRecord::Migration[8.1]
  def change
    add_column :ticketing_tickets, :analysis_relabeled_at, :datetime
  end
end
