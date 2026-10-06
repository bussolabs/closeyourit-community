# frozen_string_literal: true

# The reviewer is fixed when the work is claimed, like the runtime (CYAU-226/227): delivery checks against
# it, so changing the machine's or the organization's choice mid-job does not reject correct work.
# Null for attempts claimed before this column: delivery falls back to the machine's choice in force.
class AddExpectedReviewerToAgentsAttempts < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_attempts, :expected_reviewer, :string
    add_check_constraint :agents_attempts, "expected_reviewer IN ('claude', 'codex')",
                         name: "agents_attempts_expected_reviewer_valid"
  end
end
