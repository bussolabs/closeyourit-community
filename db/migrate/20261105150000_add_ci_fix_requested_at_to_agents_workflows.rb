# frozen_string_literal: true

# CYRA-1195 — marks the one fix round given after the delivered pull request's checks came back red.
class AddCiFixRequestedAtToAgentsWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_workflows, :ci_fix_requested_at, :datetime
  end
end
