# frozen_string_literal: true

# Discriminatore fra il commento scritto da una persona e la riga di servizio che l'app scrive da sé
# ("Resoconto aggiornato alla versione 2", "Aggiunta una domanda di chiarimento") — CYRA-220.
#
# Perché una colonna e non un marker HTML nel corpo, come fa oggi automation_generated?: col tetto di
# 240 caratteri in arrivo, `<!-- closeyourit-automation:… -->` si mangerebbe 48 dei 240. E un
# discriminatore in colonna si indicizza e non si può rompere riformattando il testo.
#
# default: 0 → tutte le righe esistenti diventano `human` senza backfill.
class AddKindToTicketingComments < ActiveRecord::Migration[8.1]
  def change
    add_column :ticketing_comments, :kind, :integer, null: false, default: 0
  end
end
