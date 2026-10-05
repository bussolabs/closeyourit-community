# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Revisore del ticket come sub-resource singleton: PUT = imposta il revisore, DELETE = rimuove.
      # Gate `tickets.assign` (come l'assegnatario e come Member::TicketsController#reviewer). Logica in
      # Ticketing::SetReviewer (reviewer fuori org → non impostato, anti-BOLA; reviewer_id blank / DELETE =
      # rimuove; no-op se invariato). Il ping al revisore scatta solo all'ingresso in uno status review_gate
      # (nel service). Anti-BOLA: ticket dentro @project (visible_projects) → fuori scope = R404.
      class ReviewersController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        def update
          return unless require_permission!("tickets.assign", scope: @project)

          set_reviewer(params[:reviewer_id])
        end

        # DELETE = rimuove il revisore: reviewer_id nil → SetReviewer azzera.
        def destroy
          return unless require_permission!("tickets.assign", scope: @project)

          set_reviewer(nil)
        end

        private

        def set_reviewer(reviewer_id)
          render_change(Ticketing::SetReviewer.call(
            organization: Current.organization, ticket: @ticket, reviewer_id: reviewer_id,
            actor: Current.account, true_actor: Current.account
          ))
        end

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
