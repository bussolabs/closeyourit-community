# frozen_string_literal: true

# Toggle personale per la sorgente "performance" (alert metric_threshold), accanto a
# errors_enabled/uptime_enabled. Default true: chi non personalizza riceve gli alert di performance.
class AddPerformanceEnabledToAlertingPreferences < ActiveRecord::Migration[8.1]
  def change
    add_column :alerting_preferences, :performance_enabled, :boolean, default: true, null: false
  end
end
