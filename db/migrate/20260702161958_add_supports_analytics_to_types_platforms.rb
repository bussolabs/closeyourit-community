class AddSupportsAnalyticsToTypesPlatforms < ActiveRecord::Migration[8.1]
  def up
    add_column :types_platforms, :supports_analytics, :boolean, default: false, null: false

    # Backfill: le piattaforme web esistenti diventano analytics-capable (Types::InstallDefaults
    # gira solo per le org nuove, come per supports_uptime).
    execute "UPDATE types_platforms SET supports_analytics = TRUE WHERE code = 'web'"
  end

  def down
    remove_column :types_platforms, :supports_analytics
  end
end
