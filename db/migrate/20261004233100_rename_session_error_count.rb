# frozen_string_literal: true

class RenameSessionErrorCount < ActiveRecord::Migration[8.1]
  def change
    rename_column :session_health_sessions, :errors, :errors_count
  end
end
