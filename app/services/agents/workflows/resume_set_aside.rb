# frozen_string_literal: true

module Agents
  module Workflows
    # CYRA-1364 — a ticket allowed again after its work was set aside (ExhaustedBudget) starts over from triage,
    # with a fresh budget. Only a run the server closed: a person's cancel stays where it is. A person needs the
    # same role as the restart button; the server's own restart is capped per ticket so it cannot loop.
    class ResumeSetAside < ApplicationService
      AUTOMATIC_LIMIT = 2

      # Result.ok(:restarted | :needs_admin | :limit_reached), or Result.ok(nil) when there is nothing to resume.
      def initialize(ticket:, actor: nil, by_server: false)
        @ticket = ticket
        @actor = actor
        @by_server = by_server
      end

      def call
        outcome = nil
        ApplicationRecord.transaction do
          @ticket.lock!
          workflow = @ticket.agent_workflow
          next unless resumable?(workflow)

          outcome = refusal || restart(workflow)
        end
        outcome || Result.ok(nil)
      end

      # What a person reads after allowing the ticket, the same on the page and in the CLI: nil when nothing is closed.
      def self.outcome_key(ticket, result)
        outcome = result&.ok? ? result.value : nil
        return outcome.to_s if outcome

        "cancelled" if ticket.agent_workflow&.cancelled_at?
      end

      def self.automatic_limit_reached?(ticket)
        ticket.events.where(action: "workflow_resumed_automatically").count >= AUTOMATIC_LIMIT
      end

      private

      # R-3: an approved delivery owns its release number and is never set aside; checked again all the same.
      def resumable?(workflow)
        ExhaustedBudget.set_aside?(workflow) && !workflow.autopilot_approved_at? &&
          @ticket.agent_eligibility_allowed? && !@ticket.status&.category_done?
      end

      def refusal
        return Result.ok(:needs_admin) unless @by_server || admin?

        Result.ok(:limit_reached) if @by_server && self.class.automatic_limit_reached?(@ticket)
      end

      def restart(workflow)
        result = Restart.call(workflow:, actor: @actor, by_server: @by_server)
        return result if result.err?

        Ticketing::RecordActivity.call(ticket: @ticket, actor: @actor, actor_name: (system_actor if @by_server),
                                       action: @by_server ? "workflow_resumed_automatically" : "workflow_resumed")
        Result.ok(:restarted)
      end

      def admin?
        @ticket.project.organization.memberships.find_by(account: @actor)&.role.in?(%w[admin owner])
      end

      def system_actor = I18n.t("agents.supporter.activity_actor")
    end
  end
end
