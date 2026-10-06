# frozen_string_literal: true

# The OpenRouter model OpenCode reviews with is fixed when the work is claimed, like the reviewer (CYAU-228):
# changing the Automator page mid-job does not change the model a re-claim is told to use.
class AddExpectedReviewerModelToAgentsAttempts < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_attempts, :expected_reviewer_model, :string
  end
end
