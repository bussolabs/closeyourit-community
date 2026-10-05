# frozen_string_literal: true

class AddTelemetryToAgentsHosts < ActiveRecord::Migration[8.1]
  def change
    change_table :agents_hosts, bulk: true do |t|
      t.jsonb :runtimes, null: false, default: []
      t.jsonb :repositories, null: false, default: []
      t.integer :running, null: false, default: 0
      t.integer :slots, null: false, default: 1
      t.string :host_status, null: false, default: "idle"
      t.jsonb :active_runs, null: false, default: []
      t.datetime :last_heartbeat_at
      t.integer :heartbeat_expected_interval_minutes, null: false, default: 60
      t.integer :heartbeat_grace_minutes, null: false, default: 5
      t.references :heartbeat_project, type: :uuid, null: true,
                                       foreign_key: { to_table: :projects, on_delete: :nullify }
    end

    add_index :agents_hosts, %i[organization_id last_heartbeat_at], name: "index_agents_hosts_on_org_heartbeat"
    add_check_constraint :agents_hosts, "jsonb_typeof(runtimes) = 'array'",
                         name: "agents_hosts_runtimes_array"
    add_check_constraint :agents_hosts, "jsonb_typeof(repositories) = 'array'",
                         name: "agents_hosts_repositories_array"
    add_check_constraint :agents_hosts, "jsonb_typeof(active_runs) = 'array'",
                         name: "agents_hosts_active_runs_array"
    add_check_constraint :agents_hosts, "running >= 0", name: "agents_hosts_running_nonnegative"
    add_check_constraint :agents_hosts, "slots > 0", name: "agents_hosts_slots_positive"
    add_check_constraint :agents_hosts,
                         "host_status IN ('idle', 'busy', 'waiting', 'recovery_required')",
                         name: "agents_hosts_status"
    add_check_constraint :agents_hosts, "heartbeat_expected_interval_minutes > 0",
                         name: "agents_hosts_heartbeat_interval_positive"
    add_check_constraint :agents_hosts, "heartbeat_grace_minutes >= 0",
                         name: "agents_hosts_heartbeat_grace_nonnegative"
  end
end
