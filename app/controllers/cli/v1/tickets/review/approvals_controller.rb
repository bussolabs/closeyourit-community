# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      module Review
        # Approvazione della review come sub-resource: POST = porta il ticket sul primo status
        # done. Gate `tickets.edit`. Logica in Ticketing::ApproveReview.
        class ApprovalsController < Cli::V1::BaseController
          before_action :set_project!
          before_action :set_ticket

          def create
            return unless require_permission!("tickets.edit", scope: @project)

            render_change(::Ticketing::ApproveReview.call(
              organization: Current.organization, ticket: @ticket,
              actor: Current.account, true_actor: Current.account
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
