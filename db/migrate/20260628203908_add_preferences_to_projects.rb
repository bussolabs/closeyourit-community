# frozen_string_literal: true

class AddPreferencesToProjects < ActiveRecord::Migration[8.1]
  def change
    # Preferenze per-progetto (jsonb). Per ora: logs_retention_days (override della retention log).
    add_column :projects, :preferences, :jsonb, null: false, default: {}
  end
end
