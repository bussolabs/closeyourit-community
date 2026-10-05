# frozen_string_literal: true

module Member
  module Tickets
    module Review
      # Approvazione della review (click con conferma nella ticket-show): porta il ticket sul
      # primo status done. Stesso gate del cambio stato (tickets.edit). Thin: la logica vive
      # in Ticketing::ApproveReview.
      class ApprovalsController < Member::BaseController
        before_action :set_ticket
        before_action :require_edit_permission!

        def create
          result = ::Ticketing::ApproveReview.call(
            organization: Current.organization, ticket: @ticket,
            actor: Current.account, true_actor: Current.true_account
          )
          if result.ok?
            redirect_back fallback_location: member_ticket_path(@ticket), notice: t("member.tickets.review_approved")
          else
            redirect_back fallback_location: member_ticket_path(@ticket), alert: result.error.message
          end
        end

        private

        # Anti-BOLA + scoping: ticket non visibile (o di altra org) → RecordNotFound (404).
        def set_ticket
          @ticket = visible.tickets.find(params[:ticket_id])
        end

        def require_edit_permission!
          require_permission!("tickets.edit", scope: @ticket.project)
        end
      end
    end
  end
end
