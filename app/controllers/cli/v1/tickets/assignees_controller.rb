# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Assegnatario del ticket come sub-resource singleton: PUT = assegna, DELETE = disassegna.
      # Gate `tickets.assign`. Logica in Ticketing::AssignTicket (assignee fuori org → resta non
      # assegnato, anti-BOLA; assignee_id nil = disassegna).
      class AssigneesController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        def update
          return unless require_permission!("tickets.assign", scope: @project)

          assign(params[:assignee_id])
        end

        # DELETE = disassegna: assignee_id nil → AssignTicket rimuove l'assegnatario.
        def destroy
          return unless require_permission!("tickets.assign", scope: @project)

          assign(nil)
        end

        private

        def assign(assignee_id)
          render_change(Ticketing::AssignTicket.call(
            organization: Current.organization, ticket: @ticket, assignee_id: assignee_id,
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
