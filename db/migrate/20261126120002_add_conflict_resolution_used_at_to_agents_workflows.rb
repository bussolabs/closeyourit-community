# frozen_string_literal: true

# CYRA-1154 — `conflict_resolution_requested_at` is cleared at every delivery, so the delivery born from a
# resolution round looked like a fresh one. This mark stays: the round was used, whichever path asked for it.
class AddConflictResolutionUsedAtToAgentsWorkflows < ActiveRecord::Migration[8.1]
  def up
    add_column :agents_workflows, :conflict_resolution_used_at, :datetime
    execute <<~SQL.squish
      UPDATE agents_workflows SET conflict_resolution_used_at = conflict_resolution_requested_at
      WHERE conflict_resolution_requested_at IS NOT NULL
    SQL
  end

  def down
    remove_column :agents_workflows, :conflict_resolution_used_at
  end
end
