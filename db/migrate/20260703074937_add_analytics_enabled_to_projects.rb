# Toggle per-progetto "Raccogli analytics" (opt-in, default false, nessun backfill): gata select/nav
# dashboard analytics (con analytics_capable) e l'ingest dei pageview. Vedi Projects::Project.
class AddAnalyticsEnabledToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :analytics_enabled, :boolean, default: false, null: false
  end
end
