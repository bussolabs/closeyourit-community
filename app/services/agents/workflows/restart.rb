# frozen_string_literal: true

module Agents
  module Workflows
    # CYRA-1070 — a cancelled run is replaced by a new one that starts from triage, as when the ticket
    # is born. One workflow per ticket (unique index), so the cancelled one goes; the ticket history keeps the cancel.
    class Restart < ApplicationService
      include ConcludedTicketGate

      # CYRA-1327 — `by_server:` is the restart the server decides when the attempts run out
      # (Agents::Workflows::ExhaustedBudget): it needs no manager and starts from a STOPPED run, not a
      # cancelled one. `engine:` is the engine the new run is handed to, and it is written on it.
      def initialize(workflow:, actor:, by_server: false, engine: nil)
        @workflow = workflow
        @actor = actor
        @by_server = by_server
        @engine = engine
      end

      def call
        return forbidden unless @by_server || authorized?
        return not_cancelled unless @by_server || @workflow.cancelled_at?
        return concluded_ticket if concluded_ticket?

        ticket = @workflow.ticket
        ApplicationRecord.transaction do
          ticket.lock!
          # The lease belongs to the TICKET and outlives the run it was taken for: a stopped run still
          # holds one, and leaving it there would make the new run find the ticket held by a machine
          # that is no longer working on it. Never a person's (as in Cancel, CYRA-293). Only on the
          # server's path: a cancelled run has already given its lease back.
          release_machine_lease!(ticket) if @by_server
          @workflow.destroy!
          ticket.create_agent_workflow!(triage_requested_at: Time.current, budget_restart_engine: @engine)
        end
        Result.ok(ticket.agent_workflow)
      end

      private

      def authorized?
        @workflow.organization.memberships.find_by(account: @actor)&.role.in?(%w[admin owner])
      end

      def release_machine_lease!(ticket)
        lease = ticket.agent_lease
        lease.destroy! if lease && !lease.human?
      end

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
