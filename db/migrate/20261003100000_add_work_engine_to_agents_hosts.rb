# frozen_string_literal: true

# Which engine does a machine's work (CYRA-921): Claude, the default and the behaviour so far, or Codex.
class AddWorkEngineToAgentsHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_hosts, :work_engine, :string, null: false, default: "claude"
    add_check_constraint :agents_hosts, "work_engine IN ('claude', 'codex')", name: "agents_hosts_work_engine_valid"
  end
end
