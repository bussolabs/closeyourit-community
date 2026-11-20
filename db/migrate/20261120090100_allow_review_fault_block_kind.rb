# frozen_string_literal: true

# CYRA-1330 — a phase whose review keeps hitting a technical fault stops on a cap of its own, and the
# board has to say THAT. Told as `attempt_limit` the sentence would be false twice over: it names the
# review, which never answered, and counts rejections that are zero.
class AllowReviewFaultBlockKind < ActiveRecord::Migration[8.1]
  KINDS = "'attempt_limit', 'agent_blocked', 'candidate_check', 'release_probe', 'held_by_person', " \
          "'safety_stop', 'production_approval'"

  def up
    remove_check_constraint :agents_workflows, name: "agents_workflows_blocked_kind_valido"
    add_check_constraint :agents_workflows,
                         "blocked_kind IS NULL OR blocked_kind IN (#{KINDS}, 'review_fault')",
                         name: "agents_workflows_blocked_kind_valido"
  end

  def down
    remove_check_constraint :agents_workflows, name: "agents_workflows_blocked_kind_valido"
    add_check_constraint :agents_workflows, "blocked_kind IS NULL OR blocked_kind IN (#{KINDS})",
                         name: "agents_workflows_blocked_kind_valido"
  end
end
