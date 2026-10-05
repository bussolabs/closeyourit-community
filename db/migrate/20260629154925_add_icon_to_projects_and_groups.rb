class AddIconToProjectsAndGroups < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :icon, :string
    add_column :projects_groups, :icon, :string
  end
end
