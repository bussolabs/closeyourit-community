# frozen_string_literal: true

# CYRA-77 — la pagina d'attività di un progetto filtra per azione dentro una finestra di tempo
# ("chi ha letto production questa settimana"). L'indice esistente [project_id, created_at] regge
# l'ordinamento ma lascia il filtro azione al passaggio riga per riga: un registro append-only cresce
# per sempre, quindi la scansione peggiora da sola col tempo, senza che nulla cambi nel codice.
class AddActionIndexToSecretsEvents < ActiveRecord::Migration[8.1]
  def change
    add_index :secrets_events, %i[project_id action created_at]
  end
end
