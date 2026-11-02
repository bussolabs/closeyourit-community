# frozen_string_literal: true

# Where the council works: per project, per project group, and the organization's master mode (CYRA-1133).
class AddCouncilSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :council_enabled, :boolean, null: false, default: false
    add_column :projects_groups, :council_enabled, :boolean, null: false, default: false
    add_column :agents_automator_settings, :council_mode, :string, null: false, default: "off"
    add_check_constraint :agents_automator_settings, "council_mode IN ('off', 'dry_run', 'on')",
                         name: "agents_automator_settings_council_mode_valid"
  end
end
