# Metadata comportamentale per la galleria replay: pagina d'ingresso/uscita, pagine visitate
# (set distinto) e identità utente (hashata, parità con errors_events.user_hash). Popolati dal
# recorder arricchito (closeyourit-js >= 0.5.0, che manda path/user per chunk); additivi e nullable
# → i chunk vecchi senza questi campi restano validi. Index per filtrare la lista per utente/pagina.
class AddBehaviorMetadataToReplaysSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :replays_sessions, :entry_path, :string
    add_column :replays_sessions, :last_path, :string
    add_column :replays_sessions, :pages, :jsonb, null: false, default: []
    add_column :replays_sessions, :user_hash, :string

    add_index :replays_sessions, %i[project_id user_hash]
    add_index :replays_sessions, %i[project_id entry_path]
  end
end
