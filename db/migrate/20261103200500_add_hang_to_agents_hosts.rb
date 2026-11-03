# frozen_string_literal: true

# CYRA-1178 — the last hang report of the Automator watchdog; null for automators that never send one.
class AddHangToAgentsHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_hosts, :hang, :jsonb
  end
end
