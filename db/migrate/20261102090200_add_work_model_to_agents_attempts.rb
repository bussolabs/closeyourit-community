# frozen_string_literal: true

# The model the council chose for a ticket, frozen on the attempt like the engine (CYRA-1133).
class AddWorkModelToAgentsAttempts < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_attempts, :work_model, :string
  end
end
