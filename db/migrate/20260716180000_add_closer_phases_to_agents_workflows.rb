# frozen_string_literal: true

# B.4 — Fasi di chiusura DOPO l'autopilot, con gate umano in mezzo:
# triage → plan → [CTO] → autopilot → [👤 approva] → closer_staging → closer_production → completed.
# La fase closer è tracciata dai TIMESTAMP del workflow (nessuno status dedicato): durante i closer il
# ticket resta nello status in_progress (non-done, non-review-gate) così la coda può ancora pescarlo.
# `completed_at` (già presente) segna la fine reale (closer_production consegnato), non più l'autopilot.
# FK nullify: agenti/account non si distruggono in cascata (audit-safe, coerente con *_by_agent/approved_by).
class AddCloserPhasesToAgentsWorkflows < ActiveRecord::Migration[8.1]
  def change
    change_table :agents_workflows, bulk: true do |t|
      t.datetime :autopilot_completed_at
      t.datetime :autopilot_approved_at
      t.references :autopilot_approved_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }, index: true
      t.datetime :closer_staging_started_at
      t.datetime :closer_staging_completed_at
      t.datetime :closer_production_started_at
      t.references :closer_staging_by_agent, type: :uuid, null: true,
                   foreign_key: { to_table: :agents_agents, on_delete: :nullify }, index: true
      t.references :closer_production_by_agent, type: :uuid, null: true,
                   foreign_key: { to_table: :agents_agents, on_delete: :nullify }, index: true
    end
  end
end
