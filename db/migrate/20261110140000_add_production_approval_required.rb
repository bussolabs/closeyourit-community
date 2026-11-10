# frozen_string_literal: true

# Production waits for a person's go-ahead where this is on: per project or per project group. The wait is a
# block kind of its own, so the board says what it is (CYRA-1278).
class AddProductionApprovalRequired < ActiveRecord::Migration[8.1]
  KINDS = "'attempt_limit', 'agent_blocked', 'candidate_check', 'release_probe', 'held_by_person', 'safety_stop'"

  def up
    add_column :projects, :production_approval_required, :boolean, null: false, default: false
    add_column :projects_groups, :production_approval_required, :boolean, null: false, default: false
    remove_check_constraint :agents_workflows, name: "agents_workflows_blocked_kind_valido"
    add_check_constraint :agents_workflows,
                         "blocked_kind IS NULL OR blocked_kind IN (#{KINDS}, 'production_approval')",
                         name: "agents_workflows_blocked_kind_valido"
  end

  def down
    remove_check_constraint :agents_workflows, name: "agents_workflows_blocked_kind_valido"
    add_check_constraint :agents_workflows, "blocked_kind IS NULL OR blocked_kind IN (#{KINDS})",
                         name: "agents_workflows_blocked_kind_valido"
    remove_column :projects_groups, :production_approval_required
    remove_column :projects, :production_approval_required
  end
end
