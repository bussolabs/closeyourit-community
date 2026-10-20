# frozen_string_literal: true

# The client contact of a project: tickets opened by hand in the project name them as reporter
# (CYRA-1086).
class AddOwnerToProjects < ActiveRecord::Migration[8.1]
  def change
    add_reference :projects, :owner, type: :uuid, null: true,
                                     foreign_key: { to_table: :accounts, on_delete: :nullify }
  end
end
