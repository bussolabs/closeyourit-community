# frozen_string_literal: true

# CYRA-1175 — how many jobs one machine takes at once; null keeps it at one.
class AddMaxParallelToAgentsHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_hosts, :max_parallel, :integer
  end
end
