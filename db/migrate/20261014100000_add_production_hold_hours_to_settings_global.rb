# frozen_string_literal: true

# The platform's wait before production, in whole hours. Empty by default: until someone fills it in,
# the system value (2 hours) keeps applying, so nothing changes on deploy.
class AddProductionHoldHoursToSettingsGlobal < ActiveRecord::Migration[8.1]
  def change
    add_column :settings_global, :production_hold_hours, :integer
  end
end
