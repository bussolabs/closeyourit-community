class AddDeviceContextToErrorsEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :errors_events, :os_name, :string
    add_column :errors_events, :os_version, :string
    add_column :errors_events, :app_version, :string
  end
end
