# frozen_string_literal: true

module Agents
  module Hosts
    # A GitHub token valid one hour, scoped to the repository of a ticket the host holds right now (CYRA-1058).
    # It replaces a permanent operator token on the machine: the agent may still read it, but it opens one
    # repository for one hour. Only the phases that push (autopilot and the closers) may write.
    class GithubToken < ApplicationService
      # CI results are readable in every phase: a rework must see why the pull request's checks failed. CYRA-1061
      CI_READ = { checks: "read", statuses: "read", actions: "read" }.freeze
      WRITE_PERMISSIONS = { contents: "write", pull_requests: "write", **CI_READ }.freeze
      READ_PERMISSIONS = { contents: "read", **CI_READ }.freeze
      # The closers merge the pull request and push the release tag. CYRA-1063
      WRITING_PHASES = %w[autopilot closer_staging closer_production].freeze

      def initialize(host:, ticket_reference:, client: Github::Client.new)
        @host = host
        @ticket_reference = ticket_reference.to_s.strip.upcase
        @client = client
      end

      def call
        return refuse("Host is not certified: no GitHub token is served", "R403-AGENT-010", :forbidden) unless @host.certified?

        ticket = resolve_ticket
        return refuse("Ticket not found", "R404-AGENT-007", :not_found) unless ticket

        lease = active_lease(ticket)
        return refuse("The host does not hold this ticket", "R403-AGENT-009", :forbidden) unless lease

        repository = ticket.project.github_repository
        return refuse("The ticket's project has no GitHub repository", "R404-AGENT-008", :not_found) unless repository

        Result.ok(env: "GH_TOKEN", **mint(repository, lease))
      rescue Github::Client::Error => e
        refuse(e.message, e.code, e.status)
      end

      private

      def resolve_ticket
        match = Agents::Leases::Operation::TICKET_REFERENCE.match(@ticket_reference)
        return nil unless match

        project = @host.organization.projects.find_by(key: match[1])
        return nil unless Agents::Hosts::ProjectScope.new(host: @host).allows?(project)

        project.tickets.find_by(number: match[2].to_i)
      end

      def active_lease(ticket)
        lease = Agents::Lease.find_by(ticket:)
        lease if lease&.held_by?(Agents::Leases::Holder.host(@host)) && lease.active_at?(Agents::Leases::Clock.current)
      end

      def mint(repository, lease)
        permissions = WRITING_PHASES.include?(lease.execution_phase) ? WRITE_PERMISSIONS : READ_PERMISSIONS
        @client.repository_token(repository.github_installation_id,
                                 repository: repository.full_name.split("/").last, permissions:)
      end

      def refuse(message, code, status)
        Result.err(AppError.new(message, code:, status:))
      end
    end
  end
end
