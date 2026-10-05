# frozen_string_literal: true

class AddDistributionToCrashReports < ActiveRecord::Migration[8.1]
  def change
    add_column :crashes_reports, :dist, :string
  end
end
