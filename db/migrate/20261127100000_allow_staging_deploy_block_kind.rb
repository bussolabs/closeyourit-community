# frozen_string_literal: true

# CYRA-1366 — a trial release that failed, was cancelled or never came stops the work with a kind of its
# own: told as `candidate_check` the board sent whoever decides to look at the proposal, which is fine.
class AllowStagingDeployBlockKind < ActiveRecord::Migration[8.1]
  KINDS = "'attempt_limit', 'agent_blocked', 'candidate_check', 'release_probe', 'held_by_person', " \
          "'safety_stop', 'production_approval', 'review_fault'"

  def up
    remove_check_constraint :agents_workflows, name: "agents_workflows_blocked_kind_valido"
    add_check_constraint :agents_workflows,
                         "blocked_kind IS NULL OR blocked_kind IN (#{KINDS}, 'staging_deploy')",
                         name: "agents_workflows_blocked_kind_valido"
  end

  def down
    remove_check_constraint :agents_workflows, name: "agents_workflows_blocked_kind_valido"
    add_check_constraint :agents_workflows, "blocked_kind IS NULL OR blocked_kind IN (#{KINDS})",
                         name: "agents_workflows_blocked_kind_valido"
  end
end
