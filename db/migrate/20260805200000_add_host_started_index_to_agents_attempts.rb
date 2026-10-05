# frozen_string_literal: true

# Indice per il rendimento storico di un host (CYRA-279).
#
# Le statistiche della pagina host leggono SEMPRE nella stessa forma: gli attempt di un host dentro
# una finestra temporale. C'era il solo indice su `host_id`, che porta a leggere tutta la storia
# dell'host per poi scartarne quasi tutta; la coppia la restringe già in indice.
#
# `started_at` e non `created_at`: è la colonna su cui filtra il selettore di periodo, ed è anche
# quella che ordina la lista dei ticket lavorati.
class AddHostStartedIndexToAgentsAttempts < ActiveRecord::Migration[8.1]
  def change
    add_index :agents_attempts, %i[host_id started_at]
  end
end
