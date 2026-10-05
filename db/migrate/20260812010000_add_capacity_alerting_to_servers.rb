# frozen_string_literal: true

class AddCapacityAlertingToServers < ActiveRecord::Migration[8.1]
  def change
    add_column :servers_samples, :db_connection_usage_pct, :decimal, precision: 5, scale: 2
    add_column :servers_samples, :data_volume_disk_pct, :decimal, precision: 5, scale: 2
    add_column :servers_samples, :inode_pct, :decimal, precision: 5, scale: 2

    add_column :servers_container_samples, :container_id, :string
    add_column :servers_container_samples, :running, :boolean, default: true, null: false
    add_column :servers_container_samples, :restart_count, :integer, default: 0, null: false
    add_column :servers_container_samples, :started_at, :datetime
    add_column :servers_container_samples, :oom_killed, :boolean, default: false, null: false

    add_column :servers_hosts, :resource_pressure, :jsonb, default: {}, null: false
    add_column :servers_hosts, :replication_outage, :jsonb, default: {}, null: false
    add_column :servers_hosts, :container_restart_outage, :jsonb, default: {}, null: false
  end
end
