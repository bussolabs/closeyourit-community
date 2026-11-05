# frozen_string_literal: true

# CYRA-1177 — remaining quota and pause of each engine, as sent by the Automator heartbeat (CYAU-275).
class AddAgentQuotaToAgentsHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_hosts, :agent_quota, :jsonb, null: false, default: []
    add_check_constraint :agents_hosts, "jsonb_typeof(agent_quota) = 'array'", name: "agents_hosts_agent_quota_array"
  end
end
