class AddDescriptionToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :description, :text
  end
end
