# frozen_string_literal: true

module Agents
  module Workflows
    # CYRA-1070 — a cancelled run is replaced by a new one that starts from triage, as when the ticket
    # is born. One workflow per ticket (unique index), so the cancelled one goes; the ticket history keeps the cancel.
    class Restart < ApplicationService
      include ConcludedTicketGate

      def initialize(workflow:, actor:)
        @workflow = workflow
        @actor = actor
      end

      def call
        membership = @workflow.organization.memberships.find_by(account: @actor)
        return forbidden unless membership&.role.in?(%w[admin owner])
        return not_cancelled unless @workflow.cancelled_at?
        return concluded_ticket if concluded_ticket?

        ticket = @workflow.ticket
        ApplicationRecord.transaction do
          ticket.lock!
          @workflow.destroy!
          ticket.create_agent_workflow!(triage_requested_at: Time.current)
        end
        Result.ok(ticket.agent_workflow)
      end

      private

      def forbidden
        Result.err(AppError.new("Non puoi riavviare questa automazione",
                                code: "R403-WORKFLOW-003", status: :forbidden))
      end

      def not_cancelled
        Result.err(AppError.new("Si riavvia solo una lavorazione annullata",
                                code: "R409-WORKFLOW-016", status: :conflict))
      end
    end
  end
end
