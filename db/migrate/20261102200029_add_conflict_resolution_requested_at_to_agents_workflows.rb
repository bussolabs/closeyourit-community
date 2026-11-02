# frozen_string_literal: true

# A code conflict with main gets one resolution attempt before it waits for a person (CYAU-300).
class AddConflictResolutionRequestedAtToAgentsWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_workflows, :conflict_resolution_requested_at, :datetime
  end
end
