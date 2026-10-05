# Toggle opt-in della raccolta session replay (default false, come analytics_enabled).
# L'ingest dei chunk è gata su questo flag: registrare la navigazione è PII, si attiva
# esplicitamente per progetto. La retention custom vive in preferences (jsonb).
class AddSessionReplayEnabledToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :session_replay_enabled, :boolean, null: false, default: false
  end
end
