# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Milestone del ticket come sub-resource singleton: PUT = imposta, DELETE = rimuove.
      # Gate `tickets.edit`. Logica in Ticketing::ChangeMilestone (milestone di un altro progetto →
      # R422, anti-BOLA; milestone_id nil = rimuove).
      class MilestonesController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        def update
          return unless require_permission!("tickets.edit", scope: @project)

          change(params[:milestone_id])
        end

        # DELETE = rimuove: milestone_id nil → ChangeMilestone toglie la milestone dal ticket.
        def destroy
          return unless require_permission!("tickets.edit", scope: @project)

          change(nil)
        end

        private

        def change(milestone_id)
          render_change(Ticketing::ChangeMilestone.call(
            organization: Current.organization, ticket: @ticket, milestone_id: milestone_id,
            actor: Current.account, true_actor: Current.account
          ))
        end

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
