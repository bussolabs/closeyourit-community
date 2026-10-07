# frozen_string_literal: true

module Member
  module Tickets
    # CYAU-235 — a person marks a decision the supporter took alone as seen. Seeing it neither approves nor
    # undoes it: it only leaves "To review". Same lever as answering a question on the ticket: tickets.edit.
    class SupporterDecisionsController < Member::BaseController
      def seen
        ticket = visible.tickets.find(params[:ticket_id])
        require_permission!("tickets.edit", scope: ticket.project)
        return if performed?

        decision = ::Agents::SupporterDecision.where(organization: current_organization, workflow: ticket.agent_workflow)
                                              .find(params[:id])
        decision.mark_seen!(by: Current.account) if decision.seen_at.nil?
        redirect_to member_ticket_path(ticket, tab: "questions"), notice: t("member.tickets.questions.supporter.seen_done")
      end
    end
  end
end
