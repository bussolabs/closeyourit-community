# frozen_string_literal: true

# CYRA-1030 — when a staging number's CHANGELOG heading was seen on main. A release sent back to staging
# keeps that number: the heading stays there, so nothing may renumber it. Empty for every existing row.
class AddLandedAtToAgentsReleaseAssignments < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_release_assignments, :landed_at, :datetime
  end
end
