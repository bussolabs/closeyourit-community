# frozen_string_literal: true

# CYRA-1159 — data only: the steps the organizations already took get the day they took them, so a
# mature organization does not see a list of things it has done for months. Insert if absent, so it
# can run again without moving a day.
class BackfillOrganizationFirstSteps < ActiveRecord::Migration[8.1]
  def up
    Organizations::Organization.reset_column_information
    Organizations::FirstStep.reset_column_information
    say_with_time("backfill organization_first_steps") { Organizations::FirstSteps::Backfill.call }
  end

  # Nothing to undo here: a rebuilt step looks like a live one, and the rollback of the previous
  # migration drops the table with every step in it.
  def down; end
end
