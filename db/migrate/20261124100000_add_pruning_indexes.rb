# frozen_string_literal: true

class AddPruningIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    # Rebuild interrupted concurrent indexes, which can remain invalid. CYRA-1268.
    down
    add_index :alerting_notifications, :created_at,
              name: "idx_alerting_notifications_retention", algorithm: :concurrently
    add_index :analytics_web_vitals, [ :project_id, :created_at ],
              name: "idx_analytics_web_vitals_retention", algorithm: :concurrently
  end

  def down
    remove_index :alerting_notifications, name: "idx_alerting_notifications_retention",
                 algorithm: :concurrently, if_exists: true
    remove_index :analytics_web_vitals, name: "idx_analytics_web_vitals_retention",
                 algorithm: :concurrently, if_exists: true
  end
end
