# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      module Review
        # Rifiuto della review come sub-resource: POST = respinge col motivo (param `reason`).
        # Gate `tickets.edit` (stesso del cambio stato). Logica in Ticketing::RejectReview
        # (guard review-gate, target in progress, evento + commento).
        class RejectionsController < Cli::V1::BaseController
          before_action :set_project!
          before_action :set_ticket

          def create
            return unless require_permission!("tickets.edit", scope: @project)

            # `mode` è opzionale e assente vale :hold (il comportamento storico): una CLI vecchia, o
            # un'integrazione che non lo conosce, non deve far ripartire una lavorazione senza chiederlo.
            render_change(::Ticketing::RejectReview.call(
              organization: Current.organization, ticket: @ticket, reason: params[:reason],
              actor: Current.account, true_actor: Current.account, mode: params[:mode]
            ))
          end

          private

          # Anti-BOLA: ticket dentro @project (già ristretto a visible_projects) → fuori scope = R404.
          def set_ticket
            @ticket = find_ticket!(@project, params[:ticket_id])
          end

          def render_change(result)
            if result.ok?
              render_ok(TicketSerializer.new(result.value))
            else
              render_error(result.error.code, result.error.message,
                           status: result.error.status, details: result.error.details)
            end
          end
        end
      end
    end
  end
end
