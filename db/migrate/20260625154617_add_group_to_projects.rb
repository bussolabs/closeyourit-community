class AddGroupToProjects < ActiveRecord::Migration[8.1]
  def change
    add_reference :projects, :group, type: :uuid, null: true,
                  foreign_key: { to_table: :projects_groups }, index: true
  end
end
