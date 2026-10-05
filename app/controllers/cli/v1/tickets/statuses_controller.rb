# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Stato del ticket come sub-resource singleton: PUT = cambia status. Gate `tickets.edit`.
      # Logica in Ticketing::ChangeStatus (no-op se invariato, R422 se lo status è fuori org).
      class StatusesController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        def update
          return unless require_permission!("tickets.edit", scope: @project)

          render_change(Ticketing::ChangeStatus.call(
            organization: Current.organization, ticket: @ticket, status_id: params[:status_id],
            channel: :cli, actor: Current.account, true_actor: Current.account
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
