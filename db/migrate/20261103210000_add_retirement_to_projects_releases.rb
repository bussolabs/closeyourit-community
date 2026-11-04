# frozen_string_literal: true

# CYRA-1161 — a release can be retired with a message for its users, and restored.
class AddRetirementToProjectsReleases < ActiveRecord::Migration[8.1]
  def change
    add_column :projects_releases, :retired_at, :datetime
    add_column :projects_releases, :retirement_message, :text
    add_reference :projects_releases, :retired_by, type: :uuid,
                                                   foreign_key: { to_table: :accounts, on_delete: :nullify }
  end
end
