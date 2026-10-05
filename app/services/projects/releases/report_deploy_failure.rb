# frozen_string_literal: true

module Projects
  module Releases
    # CYRA-871 — la CI ha trovato la produzione giù o con la versione sbagliata dopo il deploy: si apre
    # un ticket per il CTO effettivo, uno per versione. Rilanciare lo stesso rilascio lo ritrova e basta.
    class ReportDeployFailure < ApplicationService
      Outcome = Data.define(:ticket, :created)

      def initialize(project:, version:, reason:, run_url:)
        @project = project
        @version = version
        @reason = reason.to_s.strip
        @run_url = run_url.to_s.strip
      end

      def call
        cto = @project.effective_cto
        return no_cto unless cto&.human?

        @project.with_lock do
          existing = open_ticket
          next Result.ok(Outcome.new(ticket: existing, created: false)) if existing

          created = Ticketing::CreateTicket.call(organization: @project.organization, reporter: cto,
                                                 params: ticket_params)
          created.ok? ? Result.ok(Outcome.new(ticket: created.value, created: true)) : created
        end
      end

      private

      def title = "Il rilascio #{@version} non è in piedi in produzione"

      def open_ticket
        @project.tickets.joins(:status)
                .where.not(types_ticket_statuses: { category: Types::TicketStatus.categories.fetch("done") })
                .find_by(title:)
      end

      def ticket_params
        organization = @project.organization
        { project_id: @project.id, kind: :bug, title:,
          description: [ "Il controllo dopo il deploy non ha trovato #{@version} in piedi in produzione.",
                         (@reason.presence && "Motivo: #{@reason}"),
                         (@run_url.presence && "CI: #{@run_url}") ].compact.join("\n\n"),
          status_id: (organization.ticket_statuses.find_by(code: "open") ||
                      organization.ticket_statuses.active.ordered.first)&.id,
          priority_id: (organization.ticket_priorities.find_by(code: "high") ||
                        organization.ticket_priorities.active.ordered.first)&.id }
      end

      def no_cto
        Result.err(AppError.new("Il progetto non ha un CTO a cui assegnare il guasto del rilascio",
                                code: "R409-RELEASE-001", status: :conflict))
      end
    end
  end
end
