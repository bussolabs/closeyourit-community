# frozen_string_literal: true

module Agents
  module Workflows
    # The council decided what to build, so its tickets' plans need no CTO (CYRA-1133). Only with the
    # council on; every other ticket still waits for the CTO. The delivery stays with a person (AutoApprove).
    class CouncilApprovePlan < ApplicationService
      include ConcludedTicketGate

      def initialize(workflow:)
        @workflow = workflow
      end

      def call
        return Result.ok(nil) unless council_ticket? && council_on?
        return Result.ok(nil) if concluded_ticket?

        approved = ApplicationRecord.transaction do
          @workflow.lock!
          plan = @workflow.plans.reorder(version: :desc).lock.first
          next false unless plan && @workflow.planned_at? && plan.approved_at.nil? && plan.change_request.blank?
          # CYRA-1152 — approving an epic's split creates tickets: that waits for a person.
          next false if plan.split?

          FreezePlan.call(workflow: @workflow, plan:, actor: nil, now: Time.current)
          record_activity!
          true
        end
        Result.ok(approved ? @workflow : nil)
      end

      private

      def council_ticket? = Agents::CouncilProposal.exists?(ticket_id: @workflow.ticket_id)
      def council_on? = Agents::AutomatorSetting.for(@workflow.organization).council_mode == "on"

      def record_activity!
        Ticketing::RecordActivity.call(ticket: @workflow.ticket, action: "plan_council_approved",
                                       actor_name: I18n.t("agents.council.activity_actor"), data: {})
      end
    end
  end
end
