# frozen_string_literal: true

# Rework host-first (CYAU-92): il deferral (salta-ticket in coda) passa da agent-scoped a
# host+ticket+execution_phase (per-host, decisione utente D1 — ogni host ha il proprio backoff).
# Additiva/reversibile:
# - `execution_phase` (nullable a DB; popolato dal servizio Defer e richiesto dal modello).
# - `agent_id` reso nullable + FK CASCADE→SET NULL: le righe host-first non hanno agente e, in compat,
#   cancellare l'agente (CYAU-85) NON deve eliminare un deferral host+ticket+phase valido (gemello di
#   agents_attempts.agent_id, ON DELETE nullify).
# - indice di eleggibilità ricablato da [agent_id, ticket_id, retry_at] a
#   [host_id, ticket_id, execution_phase, retry_at] (stesso nome), che next.rb/claim.rb interrogano.
# - indice unico di replay esteso con host_id: il selection token non è host-bound (firma per-agente in
#   compat), quindi lo stesso token da due host deve produrre due deferral distinti (replay per-host).
#
# Backfill difensivo di execution_phase dalle righe legacy; atteso 0 righe (sistema dormiente).
# `agents_commands.workflow_type` è un enum INTEGER-backed ({triage:0,planner:1,autopilot:2,
# closer_staging:3,closer_production:4}) → il CASE traduce l'intero al nome della fase (assegnarlo grezzo
# scriverebbe '0'/'1', mai combacianti). Backfill AUTOCONTENUTO (lezione CYAU-83: mai service da migration).
class DeferralsHostPhaseScoped < ActiveRecord::Migration[8.1]
  def up
    add_column :agents_ticket_queue_deferrals, :execution_phase, :string

    execute(<<~SQL.squish)
      UPDATE agents_ticket_queue_deferrals AS d
      SET execution_phase = CASE c.workflow_type
        WHEN 0 THEN 'triage'
        WHEN 1 THEN 'planner'
        WHEN 2 THEN 'autopilot'
        WHEN 3 THEN 'closer_staging'
        WHEN 4 THEN 'closer_production'
      END
      FROM agents_agents a
      JOIN agents_commands c ON c.id = a.command_id
      WHERE d.agent_id = a.id AND d.execution_phase IS NULL
    SQL

    change_column_null :agents_ticket_queue_deferrals, :agent_id, true
    remove_foreign_key :agents_ticket_queue_deferrals, column: :agent_id
    add_foreign_key :agents_ticket_queue_deferrals, :agents_agents, column: :agent_id, on_delete: :nullify

    remove_index :agents_ticket_queue_deferrals, name: "index_agent_queue_deferrals_selection"
    add_index :agents_ticket_queue_deferrals, %i[organization_id selection_digest host_id], unique: true,
              name: "index_agent_queue_deferrals_selection"

    remove_index :agents_ticket_queue_deferrals, name: "index_agent_queue_deferrals_eligibility"
    add_index :agents_ticket_queue_deferrals, %i[host_id ticket_id execution_phase retry_at],
              name: "index_agent_queue_deferrals_eligibility"
  end

  def down
    if connection.select_value("SELECT 1 FROM agents_ticket_queue_deferrals WHERE agent_id IS NULL LIMIT 1")
      raise ActiveRecord::IrreversibleMigration,
            "Esistono deferral host-first (agent_id NULL): ripristinare agent_id NOT NULL li perderebbe."
    end

    # Replay multi-host (CYAU-92): due host con lo stesso token producono righe con identico
    # (organization_id, selection_digest). Il vecchio indice unico (organization_id, selection_digest) non le
    # ammette → il rollback è irreversibile finché non le si consolida a mano (scelta distruttiva, non automatizzata).
    multi_host_replay = connection.select_value(<<~SQL.squish)
      SELECT 1 FROM agents_ticket_queue_deferrals
      GROUP BY organization_id, selection_digest HAVING count(*) > 1 LIMIT 1
    SQL
    if multi_host_replay
      raise ActiveRecord::IrreversibleMigration,
            "Esistono replay multi-host con lo stesso (organization_id, selection_digest): l'indice unico " \
            "originale non è ripristinabile senza consolidarli manualmente."
    end

    remove_index :agents_ticket_queue_deferrals, name: "index_agent_queue_deferrals_eligibility"
    add_index :agents_ticket_queue_deferrals, %i[agent_id ticket_id retry_at],
              name: "index_agent_queue_deferrals_eligibility"

    remove_index :agents_ticket_queue_deferrals, name: "index_agent_queue_deferrals_selection"
    add_index :agents_ticket_queue_deferrals, %i[organization_id selection_digest], unique: true,
              name: "index_agent_queue_deferrals_selection"

    remove_foreign_key :agents_ticket_queue_deferrals, column: :agent_id
    add_foreign_key :agents_ticket_queue_deferrals, :agents_agents, column: :agent_id, on_delete: :cascade

    change_column_null :agents_ticket_queue_deferrals, :agent_id, false
    remove_column :agents_ticket_queue_deferrals, :execution_phase
  end
end
