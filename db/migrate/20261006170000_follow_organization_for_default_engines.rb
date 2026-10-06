# frozen_string_literal: true

# Machines still on the starting engines (Claude works, Codex reviews) follow the organization's choice
# (CYAU-227), so the Automator page applies to them. Their engines do not change: an organization that
# never chose works with Claude and reviews with Codex. Machines with any other choice keep it.
class FollowOrganizationForDefaultEngines < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE agents_hosts SET work_engine = NULL, reviewer = NULL
      WHERE work_engine = 'claude' AND reviewer = 'codex'
        AND NOT EXISTS (
          SELECT 1 FROM agents_automator_settings AS settings
          WHERE settings.organization_id = agents_hosts.organization_id
            AND (settings.work_engine <> 'claude' OR settings.reviewer <> 'codex')
        )
    SQL
  end

  # Following machines can keep following: nothing to give back.
  def down; end
end
