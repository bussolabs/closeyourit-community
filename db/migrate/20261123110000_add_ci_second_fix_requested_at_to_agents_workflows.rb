# frozen_string_literal: true

# Red checks get a second fix round when the failing checks are not the ones of the first round (CYRA-1353).
class AddCiSecondFixRequestedAtToAgentsWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_workflows, :ci_second_fix_requested_at, :datetime
  end
end
