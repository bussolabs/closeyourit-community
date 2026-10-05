# frozen_string_literal: true

module Agents
  module Workflows
    class RequestPlanChanges < ApplicationService
      include CtoGate
      include ConcludedTicketGate

      def initialize(workflow:, actor:, reason:)
        @workflow = workflow
        @actor = actor
        @reason = reason.to_s.strip
      end

      def call
        return forbidden unless authorized_cto?
        return invalid if @reason.blank?
        return concluded_ticket if concluded_ticket?

        ApplicationRecord.transaction do
          @workflow.lock!
          plan = @workflow.plans.reorder(version: :desc).lock.first!
          return stale unless @workflow.planned_at? && plan.approved_at.nil? && plan.change_request.blank?

          plan.update!(change_request: @reason)
          # Chiedere modifiche riaccoda il planner: senza azzerare anche il blocco (CYRA-218) la richiesta
          # resterebbe inevasa per sempre, perché la fase non verrebbe più offerta a nessun host.
          @workflow.update!(planned_at: nil, approved_at: nil, approved_by: nil,
                            **Agents::Workflow.cleared_block)
        end
        Result.ok(@workflow)
      rescue ActiveRecord::RecordNotFound
        stale
      end

      private

      def invalid
        Result.err(AppError.new("La motivazione è obbligatoria", code: "R422-WORKFLOW-001"))
      end

      def stale
        Result.err(AppError.new("La versione del piano non è più modificabile",
                                code: "R409-WORKFLOW-001", status: :conflict))
      end
    end
  end
end
