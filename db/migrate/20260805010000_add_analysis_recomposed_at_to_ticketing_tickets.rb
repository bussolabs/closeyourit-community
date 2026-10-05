# frozen_string_literal: true

# Quando l'analisi tecnica sepolta nei vecchi commenti è stata ricomposta nel campo del ticket
# (CYRA-260). Gemella di ticketing_comments.compacted_at: stessa forma, stesso scopo — una passata di
# migrazione che deve poter essere rilanciata senza raddoppiare il testo.
#
# Marcatore sul TICKET e non sul commento perché la ricomposizione è per ticket: unisce i pezzi di un
# gruppo in un testo solo, e il "già fatto" riguarda il ticket, non le singole righe da cui viene.
#
# null → mai ricomposto. Nessun backfill: le righe esistenti sono esattamente quelle da lavorare.
class AddAnalysisRecomposedAtToTicketingTickets < ActiveRecord::Migration[8.1]
  def change
    add_column :ticketing_tickets, :analysis_recomposed_at, :datetime
  end
end
