class AddPublicStatusEnabledToUptimeMonitors < ActiveRecord::Migration[8.1]
  def change
    # Opt-in: la status page pubblica è spenta di default (privacy by default). Nessun backfill.
    add_column :uptime_monitors, :public_status_enabled, :boolean, default: false, null: false
  end
end
