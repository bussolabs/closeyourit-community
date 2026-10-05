# frozen_string_literal: true

class BackfillCapacityAlertingRules < ActiveRecord::Migration[8.1]
  # Interi grezzi append-only di Alerting::Rule. La migrazione non dipende dal model applicativo.
  DEFAULTS = [
    { event_type: 36, name: "Database connection usage", threshold: 80 },
    { event_type: 37, name: "Data volume usage", threshold: 85 },
    { event_type: 38, name: "Filesystem inode usage", threshold: 80 },
    { event_type: 39, name: "Replication disconnected" },
    { event_type: 40, name: "Replication recovered" },
    { event_type: 41, name: "Container restart loop" },
    { event_type: 42, name: "Container stable" }
  ].freeze

  class Organization < ActiveRecord::Base
    self.table_name = "organizations"
  end

  class Rule < ActiveRecord::Base
    self.table_name = "alerting_rules"
  end

  def up
    Rule.reset_column_information
    now = Time.current
    organization_ids = Organization.pluck(:id)

    DEFAULTS.each do |default|
      already = Rule.where(event_type: default.fetch(:event_type)).distinct.pluck(:organization_id).to_set
      rows = organization_ids.reject { |id| already.include?(id) }.map do |organization_id|
        {
          organization_id: organization_id,
          event_type: default.fetch(:event_type),
          name: default.fetch(:name),
          threshold: default[:threshold],
          enabled: true,
          throttle_seconds: 300,
          unhandled_only: false,
          created_at: now,
          updated_at: now
        }
      end
      Rule.insert_all(rows) if rows.any?
    end
  end

  def down
    # Le regole possono essere state modificate dall'utente: non è sicuro distinguerle e rimuoverle.
  end
end
