# frozen_string_literal: true

module Member
  module Tickets
    module Review
      # Rifiuto della review (dal dialog nella ticket-show): riporta il ticket in lavorazione
      # col motivo obbligatorio. Stesso gate del cambio stato (tickets.edit). Thin: la logica
      # (guard review-gate, target, evento+commento) vive in Ticketing::RejectReview.
      class RejectionsController < Member::BaseController
        before_action :set_ticket
        before_action :require_edit_permission!

        def create
          # `mode` arriva dal submit premuto nel dialog (rework | hold). Il service lo valida e
          # ripiega su :hold: da qui non passa mai una ripartenza non chiesta.
          result = ::Ticketing::RejectReview.call(
            organization: Current.organization, ticket: @ticket, reason: params[:reason],
            actor: Current.account, true_actor: Current.true_account, mode: params[:mode]
          )
          if result.ok?
            redirect_back fallback_location: member_ticket_path(@ticket), notice: t("member.tickets.review_rejected")
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
