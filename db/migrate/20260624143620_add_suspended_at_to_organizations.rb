class AddSuspendedAtToOrganizations < ActiveRecord::Migration[8.1]
  def change
    add_column :organizations, :suspended_at, :datetime
  end
end
