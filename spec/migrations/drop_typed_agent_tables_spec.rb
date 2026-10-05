# frozen_string_literal: true

require "rails_helper"

# CYRA-278 — Il catalogo typed-agent è stato SVUOTATO da RemoveTypedAgents (MT-9) ma le tabelle
# erano rimaste: sei scheletri che nessun modello mappa più e che, letti nello schema, fanno
# credere che gli agenti tipizzati esistano ancora. Questi spec guardano lo schema VERO del
# database di test, non la migration: è l'unico modo per accorgersi se un merge le riporta dentro.
RSpec.describe "Schema — catalogo typed-agent rimosso" do
  let(:connection) { ActiveRecord::Base.connection }

  # L'ordine è quello del drop: prima le foglie, poi agents_agents, per ultimo agents_commands.
  dropped_tables = %w[
    connections_agent_targets
    connections_agent_command_projects
    agents_runs
    agents_instructions
    agents_agents
    agents_commands
  ]

  dropped_tables.each do |table|
    it "non ha più la tabella #{table}" do
      expect(connection.data_source_exists?(table)).to be(false)
    end
  end

  # Le colonne restano: l'audit storico (attempt, workflow, deferral, prenotazioni) le ha già a NULL
  # da MT-9 e le righe devono sopravvivere senza il puntatore. Cade il solo vincolo, che altrimenti
  # impedirebbe il drop.
  {
    "agents_attempts" => %w[agent_id command_id instruction_id run_id],
    "agents_limit_reservations" => %w[agent_id],
    "agents_ticket_queue_deferrals" => %w[agent_id],
    "agents_workflows" => %w[autopilot_by_agent_id closer_production_by_agent_id
                             closer_staging_by_agent_id planned_by_agent_id triage_by_agent_id]
  }.each do |table, columns|
    columns.each do |column|
      it "conserva #{table}.#{column} senza vincolo verso il catalogo" do
        expect(connection.column_exists?(table, column)).to be(true)
        expect(connection.foreign_key_exists?(table, column: column)).to be(false)
      end
    end
  end
end
