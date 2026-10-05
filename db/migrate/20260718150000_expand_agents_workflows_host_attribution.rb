# frozen_string_literal: true

# Rework host-first (CYAU-83, EXPAND-ONLY): affianca ai *_by_agent_id (che RESTANO) le colonne
# *_by_host_id + *_by_service_account_id per le 5 fasi, attribuendo gli effetti all'host/SA invece che
# al typed-agent. FK ON DELETE nullify (pointer denormalizzati di comodo: l'audit immutabile è
# l'Attempt, non queste colonne). NESSUN contract: le vecchie colonne si rimuovono in una release
# successiva (dopo l'attivazione). Additiva, reversibile e AUTOCONTENUTA (nessun codice applicativo).
#
# Il backfill storico dagli Attempt è un one-shot da lanciare POST-DEPLOY via runner (convenzione repo,
# cfr Uptime::BackfillJob) — NON qui: una replay futura di db:migrate non deve dipendere da un service
# mutabile/rimovibile.
#   bin/rails runner 'Agents::Workflows::BackfillHostAttribution.call'
class ExpandAgentsWorkflowsHostAttribution < ActiveRecord::Migration[8.1]
  PHASES = %w[triage planned autopilot closer_staging closer_production].freeze

  def up
    PHASES.each do |prefix|
      add_reference :agents_workflows, :"#{prefix}_by_host", type: :uuid, null: true,
                    index: { name: "idx_agents_workflows_#{prefix}_by_host" },
                    foreign_key: { to_table: :agents_hosts, on_delete: :nullify }
      add_reference :agents_workflows, :"#{prefix}_by_service_account", type: :uuid, null: true,
                    index: { name: "idx_agents_workflows_#{prefix}_by_sa" },
                    foreign_key: { to_table: :accounts, on_delete: :nullify }
    end
  end

  def down
    PHASES.each do |prefix|
      remove_reference :agents_workflows, :"#{prefix}_by_host", foreign_key: { to_table: :agents_hosts }
      remove_reference :agents_workflows, :"#{prefix}_by_service_account", foreign_key: { to_table: :accounts }
    end
  end
end
