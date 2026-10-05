# frozen_string_literal: true

# CYRA-278 — Cadono le sei tabelle del catalogo typed-agent. RemoveTypedAgents (MT-9) le aveva
# SVUOTATE ma lasciate in piedi: scheletri che nessun modello mappa più e che, letti nello schema,
# fanno ancora credere che gli agenti tipizzati esistano — l'errore costa caro perché la prossima
# feature ci si appoggia e scopre solo a runtime che dietro non c'è niente.
#
# Le colonne che puntavano al catalogo RESTANO sulle tabelle di audit (attempt, workflow, deferral,
# prenotazioni): MT-9 le ha già messe a NULL su ogni riga storica e quelle righe devono sopravvivere
# senza il puntatore. Cade il solo vincolo, che altrimenti impedirebbe fisicamente il drop.
#
# `if_exists`/`foreign_key_exists?` rendono la migration rieseguibile su una checkout dove il drop è
# già passato: nessun errore, nessun lavoro.
class DropTypedAgentTables < ActiveRecord::Migration[8.1]
  # Vincoli ESTERNI al catalogo, quelli che il drop non porta via da sé.
  LEGACY_FOREIGN_KEYS = {
    "agents_attempts" => %w[agent_id command_id instruction_id run_id],
    "agents_limit_reservations" => %w[agent_id],
    "agents_ticket_queue_deferrals" => %w[agent_id],
    "agents_workflows" => %w[autopilot_by_agent_id closer_production_by_agent_id
                             closer_staging_by_agent_id planned_by_agent_id triage_by_agent_id]
  }.freeze

  # Ordine imposto dalle FK interne: prima le foglie, poi gli agenti, per ultimi i comandi
  # (agents_agents.command_id è ON DELETE RESTRICT).
  DROPPED_TABLES = %w[
    connections_agent_targets
    connections_agent_command_projects
    agents_runs
    agents_instructions
    agents_agents
    agents_commands
  ].freeze

  def up
    LEGACY_FOREIGN_KEYS.each do |table, columns|
      columns.each do |column|
        remove_foreign_key(table, column: column) if foreign_key_exists?(table, column: column)
      end
    end

    DROPPED_TABLES.each { |table| drop_table(table, if_exists: true) }
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Il catalogo typed-agent non si ricrea: MT-9 ne ha cancellato le righe, tornare indietro " \
          "darebbe sei tabelle vuote e vincoli che nessun dato può soddisfare."
  end
end
