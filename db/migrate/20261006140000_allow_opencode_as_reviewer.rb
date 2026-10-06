# frozen_string_literal: true

# OpenCode can review the work, never do it (CYAU-228): only the reviewer columns accept it.
class AllowOpencodeAsReviewer < ActiveRecord::Migration[8.1]
  CONSTRAINTS = {
    agents_hosts: { column: :reviewer, name: "agents_hosts_reviewer_valid" },
    agents_automator_settings: { column: :reviewer, name: "agents_automator_settings_reviewer_valid" },
    agents_attempts: { column: :expected_reviewer, name: "agents_attempts_expected_reviewer_valid" }
  }.freeze

  def up = replace_constraints(%w[claude codex opencode])

  # Rows that name OpenCode would break the old constraint: they go back to the column's former choice.
  def down
    execute "UPDATE agents_hosts SET reviewer = CASE WHEN work_engine = 'codex' THEN 'claude' ELSE 'codex' END WHERE reviewer = 'opencode'"
    execute "UPDATE agents_automator_settings SET reviewer = CASE WHEN work_engine = 'codex' THEN 'claude' ELSE 'codex' END WHERE reviewer = 'opencode'"
    execute "UPDATE agents_attempts SET expected_reviewer = NULL WHERE expected_reviewer = 'opencode'"
    replace_constraints(%w[claude codex])
  end

  private

  def replace_constraints(engines)
    allowed = engines.map { |engine| "'#{engine}'" }.join(", ")
    CONSTRAINTS.each do |table, constraint|
      remove_check_constraint table, name: constraint[:name]
      add_check_constraint table, "#{constraint[:column]} IN (#{allowed})", name: constraint[:name]
    end
  end
end
