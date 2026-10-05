# Lega ogni occorrenza di errore alla sessione di replay in corso (id opaco dal
# browser SDK, via contexts.replay.replay_id). L'indice [project_id, replay_session_id]
# permette al Monitor di trovare il replay del gruppo/occorrenza. Nessuna FK: chunk di
# replay ed errori arrivano indipendenti (mirror di trace_id).
class AddReplaySessionIdToErrorsEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :errors_events, :replay_session_id, :string
    add_index :errors_events, %i[project_id replay_session_id]
  end
end
