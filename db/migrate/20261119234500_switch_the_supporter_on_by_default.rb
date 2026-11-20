# frozen_string_literal: true

# The supporter is born on, and goes on over the projects already there: switched off, every plan and
# every stuck piece of work waited for a person (CYRA-1325). The switch stays, one per project.
class SwitchTheSupporterOnByDefault < ActiveRecord::Migration[8.1]
  def up
    change_column_default :projects, :supporter_enabled, from: false, to: true
    switch_existing_projects_on
  end

  # The default alone comes back: which projects had it off is kept nowhere.
  def down
    change_column_default :projects, :supporter_enabled, from: true, to: false
  end

  def switch_existing_projects_on
    execute("UPDATE projects SET supporter_enabled = TRUE WHERE supporter_enabled = FALSE")
  end
end
