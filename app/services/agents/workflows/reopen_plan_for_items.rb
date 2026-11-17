# frozen_string_literal: true

module Agents
  module Workflows
    # CYRA-1319 — an acceptance item changed after a v3 plan was approved and before the work started: the
    # approved proofs no longer match the ticket, so the planning runs again. Once the work started the body is
    # locked (Workflow#body_locked?) and nothing reaches here.
    module ReopenPlanForItems
      ACTION = "plan_reopened_items_changed"

      def self.call(ticket:)
        workflow = ticket.agent_workflow
        return false unless workflow&.approved_at? && !workflow.body_locked?

        ApplicationRecord.transaction do
          workflow.lock!
          plan = workflow.frozen_plan
          next false unless plan && Agents::Plans::TicketItems.v3?(plan) && !workflow.terminal?

          workflow.update!(planned_at: nil, approved_at: nil, approved_by: nil, **Agents::Workflow.cleared_block)
          Ticketing::RecordActivity.call(ticket:, action: ACTION, data: { plan_version: plan.version })
          true
        end
      end
    end
  end
end
