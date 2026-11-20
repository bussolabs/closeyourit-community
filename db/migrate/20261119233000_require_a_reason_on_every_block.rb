# frozen_string_literal: true

# CYRA-1329 — a stopped piece of work must always say why. On 2026-11-19 the decision queue held 74
# stopped rows with nothing written next to them, so nobody could tell what to do without opening the
# database.
#
# The rule belongs HERE and not only in Agents::Workflows::Block: every path that stops a piece of
# work writes these same four columns (the attempts cap, an agent's own stop, the proposal and release
# checks, a person holding a release, a safety stop), and the next one written will forget. The twin
# constraint on the author (`agents_workflows_blocco_ha_un_autore`, CYRA-598) already works this way.
#
# A NULL would NOT violate `btrim(blocked_reason) <> ''` — a check only fails on FALSE, and NULL is
# neither — so the NOT NULL is spelled out. Clearing a block (Agents::Workflow.cleared_block) empties
# `blocked_at` together with the reason, so it stays allowed.
class RequireAReasonOnEveryBlock < ActiveRecord::Migration[8.1]
  CONSTRAINT = "agents_workflows_blocco_ha_un_motivo"

  def up
    # The rows stopped before the rule existed: they get an honest placeholder rather than a made-up
    # reason, so the sentence on screen says that nothing was written instead of inventing a cause.
    execute(<<~SQL.squish)
      UPDATE agents_workflows
         SET blocked_reason = 'reason not recorded'
       WHERE blocked_at IS NOT NULL
         AND (blocked_reason IS NULL OR btrim(blocked_reason) = '')
    SQL

    add_check_constraint :agents_workflows,
                         "blocked_at IS NULL OR (blocked_reason IS NOT NULL AND btrim(blocked_reason) <> '')",
                         name: CONSTRAINT
  end

  def down
    remove_check_constraint :agents_workflows, name: CONSTRAINT
  end
end
