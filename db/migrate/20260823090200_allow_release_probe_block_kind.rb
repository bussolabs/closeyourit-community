# frozen_string_literal: true

# CYRA-624 — un rilascio che non si vede in piedi ferma la lavorazione, e chi legge deve sapere DOVE
# si è fermata. Col solo `candidate_check` la scheda avrebbe detto «si è fermata sul controllo della
# proposta»: una frase falsa nel punto esatto in cui qualcuno deve decidere.
class AllowReleaseProbeBlockKind < ActiveRecord::Migration[8.1]
  KINDS = %w[attempt_limit agent_blocked candidate_check release_probe].freeze

  def up
    remove_check_constraint :agents_workflows, name: "agents_workflows_blocked_kind_valido"
    add_check_constraint :agents_workflows,
                         "blocked_kind IS NULL OR blocked_kind IN (#{KINDS.map { |k| "'#{k}'" }.join(', ')})",
                         name: "agents_workflows_blocked_kind_valido"
  end

  def down
    remove_check_constraint :agents_workflows, name: "agents_workflows_blocked_kind_valido"
    add_check_constraint :agents_workflows,
                         "blocked_kind IS NULL OR blocked_kind IN ('attempt_limit', 'agent_blocked', 'candidate_check')",
                         name: "agents_workflows_blocked_kind_valido"
  end
end
