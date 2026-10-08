# frozen_string_literal: true

module Agents
  module Workflows
    class Cancel < ApplicationService
      include ConcludedTicketGate

      def initialize(workflow:, actor:, reason:)
        @workflow = workflow
        @actor = actor
        @reason = reason.to_s.strip
      end

      def call
        membership = @workflow.organization.memberships.find_by(account: @actor)
        return forbidden unless membership&.role.in?(%w[admin owner])
        return invalid if @reason.blank?
        return concluded_ticket if concluded_ticket?

        ApplicationRecord.transaction do
          @workflow.ticket.lock!
          @workflow.lock!
          # Solo il lease di un host: annullare l'automazione ferma gli agenti, non toglie il ticket
          # dalle mani della persona che nel frattempo lo sta lavorando (CYRA-293).
          lease = @workflow.ticket.agent_lease
          lease.destroy! if lease && !lease.human?
          @workflow.attempts.status_running.update_all(status: Agents::Attempt.statuses.fetch("cancelled"),
                                                       finished_at: Time.current, updated_at: Time.current)
          @workflow.update!(cancelled_by: @actor, cancelled_at: Time.current, cancellation_reason: @reason)
        end
        give_status_back
        Result.ok(@workflow)
      end

      private

      # CYRA-1050 — the in-progress status the run put on the ticket goes back to open. Not once the code
      # is verified on the main line (it is in staging: in review), nor while a person holds the ticket.
      def give_status_back
        ticket = @workflow.ticket
        return if @workflow.closer_staging_verified_at? || ticket.agent_lease&.human?
        return unless ticket.status&.category_in_progress?

        open_status = @workflow.organization.ticket_statuses.active.category_open.ordered.first
        return if open_status.nil?

        Ticketing::ChangeStatus.call(organization: @workflow.organization, ticket:, status_id: open_status.id,
                                     channel: :workflow, actor: @actor)
      end

      def forbidden
        Result.err(AppError.new("Non puoi annullare questa automazione",
                                code: "R403-WORKFLOW-002", status: :forbidden))
      end

      def invalid
        Result.err(AppError.new("La motivazione è obbligatoria", code: "R422-WORKFLOW-002"))
      end
    end
  end
end
