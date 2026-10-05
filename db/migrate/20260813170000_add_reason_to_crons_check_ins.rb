# frozen_string_literal: true

# CYRA-484 — un tentativo fallito diceva solo «fallito». Lo stato e la durata il check-in li accetta
# già; quello che mancava è il MOTIVO in parole, che è la sola cosa che evita di andare a cercarlo
# nei log dell'applicazione. Facoltativo e limitato: un messaggio di errore può essere lunghissimo,
# e qui serve la prima riga, non lo stack.
class AddReasonToCronsCheckIns < ActiveRecord::Migration[8.1]
  def change
    add_column :crons_check_ins, :reason, :string, limit: 500
  end
end
