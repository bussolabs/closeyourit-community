class AddServersEnabledToAlertingPreferences < ActiveRecord::Migration[8.1]
  def change
    # Toggle personale per la sorgente "servers" nel notification center (come errors/uptime/...).
    add_column :alerting_preferences, :servers_enabled, :boolean, null: false, default: true
  end
end
