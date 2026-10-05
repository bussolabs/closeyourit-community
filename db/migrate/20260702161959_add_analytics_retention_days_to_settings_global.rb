class AddAnalyticsRetentionDaysToSettingsGlobal < ActiveRecord::Migration[8.1]
  def up
    add_column :settings_global, :analytics_retention_days, :integer

    # Il livello di sistema deve sempre avere un valore (come logs_retention_days): backfill
    # della riga singleton esistente al default.
    execute "UPDATE settings_global SET analytics_retention_days = 365"
  end

  def down
    remove_column :settings_global, :analytics_retention_days
  end
end
