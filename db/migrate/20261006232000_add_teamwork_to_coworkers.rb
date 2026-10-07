# Team Puckies bound to a project, runs that know who asked and which run handed them work,
# and the role a Puck was created from (CYRA-1023, CYRA-1024, CYRA-1025).
class AddTeamworkToCoworkers < ActiveRecord::Migration[8.1]
  def change
    add_column :coworkers_puckies, :visibility, :string, null: false, default: "personal"
    add_reference :coworkers_puckies, :project, type: :uuid, foreign_key: { on_delete: :cascade }
    add_column :coworkers_puckies, :preset, :string
    add_check_constraint :coworkers_puckies, "visibility IN ('personal', 'team')", name: "coworkers_puckies_visibility_valid"
    add_check_constraint :coworkers_puckies, "visibility = 'personal' OR project_id IS NOT NULL", name: "coworkers_puckies_team_has_project"

    add_reference :coworkers_runs, :account, type: :uuid, foreign_key: { on_delete: :nullify }
    add_reference :coworkers_runs, :parent_run, type: :uuid, foreign_key: { to_table: :coworkers_runs, on_delete: :nullify }
  end
end
