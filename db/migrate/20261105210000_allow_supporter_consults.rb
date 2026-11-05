# frozen_string_literal: true

# CYRA-1197 — the supporter also judges stopped workflows: a "consult" either retries the work with guidance for
# the agent, leaves it to a person, or stops it for safety. A safety stop is a block kind of its own.
class AllowSupporterConsults < ActiveRecord::Migration[8.1]
  KINDS = "'attempt_limit', 'agent_blocked', 'candidate_check', 'release_probe', 'held_by_person'"

  def up
    remove_check_constraint :agents_workflows, name: "agents_workflows_blocked_kind_valido"
    add_check_constraint :agents_workflows, "blocked_kind IS NULL OR blocked_kind IN (#{KINDS}, 'safety_stop')",
                         name: "agents_workflows_blocked_kind_valido"
    remove_check_constraint :agents_supporter_decisions, name: "agents_supporter_decisions_target_type_valid"
    remove_check_constraint :agents_supporter_decisions, name: "agents_supporter_decisions_outcome_valid"
    add_check_constraint :agents_supporter_decisions, "target_type IN ('question', 'plan', 'consult')",
                         name: "agents_supporter_decisions_target_type_valid"
    add_check_constraint :agents_supporter_decisions,
                         "outcome IN ('answered', 'approved', 'escalated', 'retried', 'stopped')",
                         name: "agents_supporter_decisions_outcome_valid"
  end

  def down
    remove_check_constraint :agents_workflows, name: "agents_workflows_blocked_kind_valido"
    add_check_constraint :agents_workflows, "blocked_kind IS NULL OR blocked_kind IN (#{KINDS})",
                         name: "agents_workflows_blocked_kind_valido"
    remove_check_constraint :agents_supporter_decisions, name: "agents_supporter_decisions_target_type_valid"
    remove_check_constraint :agents_supporter_decisions, name: "agents_supporter_decisions_outcome_valid"
    add_check_constraint :agents_supporter_decisions, "target_type IN ('question', 'plan')",
                         name: "agents_supporter_decisions_target_type_valid"
    add_check_constraint :agents_supporter_decisions, "outcome IN ('answered', 'approved', 'escalated')",
                         name: "agents_supporter_decisions_outcome_valid"
  end
end
