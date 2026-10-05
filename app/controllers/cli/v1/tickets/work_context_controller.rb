# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Accesso d'audit allo snapshot immutabile della Guidance consegnata alla presa in carico (CYRA-76),
      # come sub-resource SINGLETON in sola lettura (pattern Projects::GuidanceController). Gate esplicito
      # `tickets.audit.view`: è materiale d'audit, non contenuto ordinario del ticket, quindi NON basta la
      # visibilità di scope. Anti-BOLA: ticket dentro @project (visible_projects) → fuori scope = R404.
      class WorkContextController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        def show
          return unless require_permission!("tickets.audit.view", scope: @project)

          snapshot = @ticket.work_context_snapshot
          # Nessuno snapshot finché il ticket non è mai stato preso in carico: 404, non una riga vuota.
          if snapshot.nil?
            return render_error("R404-TICKET-004", "Il ticket non ha ancora uno snapshot del contesto di lavoro",
                                status: :not_found)
          end

          render_ok(Ticketing::WorkContextSnapshotSerializer.new(snapshot))
        end

        private

        def set_ticket
          @ticket = find_ticket!(@project, params[:ticket_id])
        end
      end
    end
  end
end
