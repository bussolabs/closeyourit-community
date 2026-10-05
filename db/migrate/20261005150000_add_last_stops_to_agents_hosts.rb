# frozen_string_literal: true

# Why a machine last stopped before taking work, as sent by the Automator heartbeat (CYRA-999).
class AddLastStopsToAgentsHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_hosts, :last_stops, :jsonb, null: false, default: []
    add_check_constraint :agents_hosts, "jsonb_typeof(last_stops) = 'array'", name: "agents_hosts_last_stops_array"
  end
end
