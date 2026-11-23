# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # CYRA-1352 — POST moves the ticket to another project: `tickets.edit` on both, the target by id or key.
      class MovesController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        def create
          target = target_project
          return render_error("R404-SYSTEM-001", "Resource not found", status: :not_found) if target.nil?
          return unless require_permission!("tickets.edit", scope: @project)
          return unless require_permission!("tickets.edit", scope: target)

          result = Ticketing::MoveToProject.call(ticket: @ticket, project: target, actor: Current.account,
                                                 true_actor: Current.account)
          return render_ok(TicketSerializer.new(result.value)) if result.ok?

          render_error(result.error.code, result.error.message, status: result.error.status)
        end

        private

        def set_ticket
          @ticket = find_ticket!(@project, params[:ticket_id])
        end

        def target_project
          ref = params.require(:target_project).to_s.strip
          visible_projects.find_by(id: ref) || visible_projects.find_by(key: ref.upcase)
        end
      end
    end
  end
end
