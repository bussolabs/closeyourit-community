# frozen_string_literal: true

# CYAG-22 — default cluster alert rules for the organizations that already exist. New organizations
# get them from Alerting::Rules::InstallDefaults; without these rows the alerts would reach nobody.
class BackfillClusterAlertingRules < ActiveRecord::Migration[8.1]
  # Raw append-only integers of Alerting::Rule#event_type (53..58 = cluster_*).
  DEFAULTS = [
    { event_type: 53, name: "Cluster muto" },
    { event_type: 54, name: "Cluster di nuovo raggiungibile" },
    { event_type: 55, name: "Macchina del cluster non pronta" },
    { event_type: 56, name: "Macchina del cluster sotto sforzo" },
    { event_type: 57, name: "App che riparte di continuo" },
    { event_type: 58, name: "App a metà" }
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
      already = Rule.where(event_type: default[:event_type]).distinct.pluck(:organization_id).to_set
      rows = organization_ids.reject { |id| already.include?(id) }.map do |organization_id|
        { organization_id:, event_type: default[:event_type], name: default[:name], enabled: true,
          throttle_seconds: 300, unhandled_only: false, created_at: now, updated_at: now }
      end
      Rule.insert_all(rows) if rows.any?
    end
  end

  def down
    # Rules may have been edited by people: they cannot be told apart and removed safely.
  end
end
