# frozen_string_literal: true

module Agents
  module TicketQueues
    # Seleziona lo snapshot del prossimo ticket da sottoporre al preflight. Non acquisisce il lease:
    # il claim resta una mutazione separata e atomica, eseguita dall'Automator soltanto dopo i gate.
    class Next < ApplicationService
      def initialize(organization:, project_key:, host:)
        @organization = organization
        @project_key = project_key.to_s.strip.upcase
        @host = host
      end

      def call
        # Host-first (CYAU-84): il capability gate agent-based (active_agent?) è spostato host-side. Al preflight
        # basta la certificazione dell'host (revoca già respinta dall'auth); l'Eligibility completa (heartbeat,
        # capacità, runtime, scope) resta l'autorità sotto lock nel Claim.
        return host_ineligible unless @host.supported_platform? && @host.certified?

        project = target_project
        return project_not_found unless project

        Result.ok(next_ticket(project))
      end

      private

      def target_project
        Candidates.project_for(organization: @organization, host: @host, key: @project_key)
      end

      def next_ticket(project)
        candidates = Candidates.new(project:, host: @host)
        id = candidates.head_id
        return unless id

        candidates.snapshot(id)
      end

      def host_ineligible
        Result.err(AppError.new("Host non eleggibile", code: "R403-AGENT-006", status: :forbidden))
      end

      def project_not_found
        Result.err(AppError.new("Progetto non trovato", code: "R404-AGENT-002", status: :not_found))
      end
    end
  end
end
