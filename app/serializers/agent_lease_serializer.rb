# frozen_string_literal: true

# Contratto wire dell'Automator: identità umana del ticket, ownership host+run e tempo server. Host-first
# (CYAU-96): la fase eseguibile e l'impronta del profilo affiancano lo slug agent legacy (dual-stack).
# CYRA-293: il titolare può essere un account (canale CLI) invece di un host — `held_by` lo dice in
# chiaro al client, che deve poter mostrare "in lavorazione da X" senza una seconda chiamata.
class AgentLeaseSerializer < ApplicationSerializer
  attributes :run_id, :agent, :execution_phase, :profile_digest, :expires_at

  # CYRA-285: la profondità della rilettura incrociata dovuta per la fase presa in carico, decisa dal server
  # (Agents::PhaseProfile#review_depth) e consegnata all'host INSIEME al lease, cioè prima che la fase parta:
  # l'host sa così cosa chiedere al reviewer senza poterlo scegliere da sé — Attempts::Deliver rifiuta una
  # consegna che dichiari una profondità diversa. Nulla su un lease senza fase (presa in carico via CLI di un
  # account, CYRA-293): lì non c'è nessuna rilettura da chiedere. Additivo: il contratto agent-queue/v1
  # dichiara `lease.additionalProperties: true`, quindi non tocca schema né SHA256SUMS.
  attribute(:review_depth) { |lease| Agents::PhaseProfile.for(lease.execution_phase)&.review_depth }

  # CYRA-621 — il numero di versione, e per la versione definitiva anche il punto esatto di codice da
  # pubblicare. Li ha decisi il server prima che la fase partisse: la macchina li riceve e li esegue.
  # Nullo dove non c'è un rilascio da fare. Additivo: il contratto agent-queue dichiara
  # `lease.additionalProperties: true`, quindi non tocca schema né SHA256SUMS.
  attribute(:release) do |lease|
    assignment = lease.execution_phase.present? &&
                   Agents::ReleaseAssignment.find_by(workflow_id: lease.ticket.agent_workflow&.id,
                                                     execution_phase: lease.execution_phase)
    { version: assignment.version, sha: assignment.sha } if assignment
  end

  attribute(:ticket) { |lease| lease.ticket.code }
  attribute(:host_id) { |lease| lease.host_id }
  attribute(:account_id) { |lease| lease.account_id }
  attribute(:held_by) do |lease|
    {
      kind: lease.holder_kind,
      id: lease.holder_id,
      name: lease.human? ? lease.account&.name : lease.host&.hostname
    }
  end
end
