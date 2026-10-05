# Capability piattaforma per il session replay: solo il web (browser + rrweb) lo abilita. Mirror di
# supports_analytics. Gata la UI (quali progetti possono attivare il replay); l'ingest resta gated dal
# toggle progetto session_replay_enabled.
class AddSupportsSessionReplayToTypesPlatforms < ActiveRecord::Migration[8.1]
  def up
    add_column :types_platforms, :supports_session_replay, :boolean, default: false, null: false
    execute "UPDATE types_platforms SET supports_session_replay = TRUE WHERE code = 'web'"
  end

  def down
    remove_column :types_platforms, :supports_session_replay
  end
end
