# frozen_string_literal: true

# CYRA-871 — il CTO può fermare un rilascio prima della produzione («Ferma»), e la scheda deve dire
# che l'ha fermato una persona, non la revisione o la macchina.
class AllowHeldByPersonBlockKind < ActiveRecord::Migration[8.1]
  KINDS = %w[attempt_limit agent_blocked candidate_check release_probe held_by_person].freeze

  def up
    remove_check_constraint :agents_workflows, name: "agents_workflows_blocked_kind_valido"
    add_check_constraint :agents_workflows,
                         "blocked_kind IS NULL OR blocked_kind IN (#{KINDS.map { |k| "'#{k}'" }.join(', ')})",
                         name: "agents_workflows_blocked_kind_valido"
  end

  def down
    remove_check_constraint :agents_workflows, name: "agents_workflows_blocked_kind_valido"
    add_check_constraint :agents_workflows,
                         "blocked_kind IS NULL OR blocked_kind IN " \
                         "('attempt_limit', 'agent_blocked', 'candidate_check', 'release_probe')",
                         name: "agents_workflows_blocked_kind_valido"
  end
end
