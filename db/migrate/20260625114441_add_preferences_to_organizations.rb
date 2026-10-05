class AddPreferencesToOrganizations < ActiveRecord::Migration[8.1]
  def change
    add_column :organizations, :preferences, :jsonb, null: false, default: {}
  end
end
