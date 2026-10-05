# frozen_string_literal: true

module Agents
  module TicketQueues
    # Carica e rivalida lo stesso snapshot operativo per claim e defer. Claim può avere già le policy;
    # questo percorso segue il suffisso unico host → project → ticket → repository/status/dipendenze,
    # senza risalire verso organization o policy.
    class CandidateSnapshot
      Context = Data.define(:project, :ticket, :repository, :status, :workflow)

      def initialize(organization:, host:)
        @organization = organization
        @host = host
      end

      # Host-first (CYAU-84): l'API è appiattita (nessun agent_id nell'URL) e l'agent è sparito dallo snapshot.
      # L'identità/scope/capability sono host-only (token host-bound + ProjectScope + Eligibility sotto lock).
      def load(selection)
        project = @organization.projects.includes(:github_repository).find(selection[:project_id])
        ticket = project.tickets.preload(
          :status, :priority, :milestone, :platforms, :scenarios, :conditions,
          :assignee, :reporter, :reviewer, :agent_workflow, comments: :author
        ).find(selection[:ticket_id])
        repository = project.github_repository or raise ActiveRecord::RecordNotFound
        Context.new(project:, ticket:, repository:, status: ticket.status, workflow: ticket.agent_workflow)
      end

      def lock(selection)
        @host.lock!
        return if @host.revoked? || @host.organization_id != @organization.id

        project = @organization.projects.lock.find(selection[:project_id])
        ticket = project.tickets.lock.find(selection[:ticket_id])
        workflow = ticket.agent_workflow&.lock!
        repository = Github::Repository.lock.find_by!(project_id: project.id)
        status = Types::TicketStatus.lock.find(ticket.status_id)
        lock_candidate_dependencies(ticket)
        Context.new(project:, ticket:, repository:, status:, workflow:)
      end

      # Host-first (CYAU-81): la fase firmata nel token è ri-confrontata sotto lock con la fase pronta corrente
      # del workflow (rivalidazione TOCTOU) e il profile_digest è ri-derivato dal PhaseProfile (fail-closed sul
      # drift). Lo scope è la sola visibilità del service account dell'host (ProjectScope), non più il comando.
      def eligible?(context, selection)
        ready_phase = context.workflow&.ready_execution_phase
        ready_phase.present? &&
          ready_phase == selection[:execution_phase] &&
          # Gate di eleggibilità agenti (CYRA-184) ri-letto SOTTO LOCK. Non è ridondante rispetto al
          # filtro in Next: fra l'emissione del token e il claim c'è la finestra di Selection::
          # DEFAULT_TTL (5 minuti), abbastanza perché un umano blocchi il ticket dopo che è stato
          # firmato. Senza questa riga l'agente lavorerebbe un ticket già vietato.
          context.ticket.agent_workable? &&
          # CYRA-623 — i prerequisiti si ricontrollano QUI, sotto la stessa finestra: fra la firma
          # della selezione e la presa in carico ci sono cinque minuti, abbastanza perché un
          # prerequisito smetta di essere soddisfatto. Senza, la macchina comincerebbe un lavoro che
          # il cancello rifiuta alla consegna, a giro già pagato.
          #
          # SENZA lock sui prerequisiti, ed è la parte da non toccare: il dispatch locka in ordine
          # policy→host→progetto→ticket, il cancello per id ordinati. Prendere qui il lock sui blocker
          # significherebbe due transazioni che si aspettano a vicenda nell'ordine opposto.
          !open_prerequisites?(context.ticket, ready_phase) &&
          Agents::PhaseProfile.for(ready_phase)&.digest == selection[:profile_digest] &&
          Agents::Hosts::ProjectScope.new(host: @host).allows?(context.project) &&
          !context.status.category_done? &&
          Selection.candidate_version(context.ticket) == selection[:candidate_version] &&
          Selection.repository_fingerprint(context.repository) == selection[:repository_fingerprint]
      end

      private

      def open_prerequisites?(ticket, ready_phase)
        ticket.unmet_dependencies(mode: Ticketing::DependencyGuard.mode_for(ready_phase)).exists?
      end

      # Il ticket lock precede le dipendenze e serializza anche insert lease/defer tramite le FK.
      def lock_candidate_dependencies(ticket)
        Types::TicketPriority.lock.find(ticket.priority_id)
        ticket_platforms = ticket.ticket_platforms.reorder(:id).lock.to_a
        Types::Platform.where(id: ticket_platforms.map(&:platform_id)).order(:id).lock.load
        ticket.scenarios.reorder(:id).lock.load
        ticket.conditions.reorder(:id).lock.load
        ticket.comments.reorder(:id).lock.load
      end
    end
  end
end
