# frozen_string_literal: true

module Api
  module V1
    # Lettura dei gruppi d'errore del progetto del token (bearer). Scoping al solo Current.project
    # (il token pinna un progetto) → anti-BOLA implicito. Triage via sub-resource singleton.
    class ErrorGroupsController < Api::V1::BaseController
      # La lettura della telemetria richiede lo scope 'read' (CYRA-37): un token ingest-only → 403.
      before_action -> { require_scope!(:read) }

      def index
        # CYRA-738 — la lista la costruisce Errors::Groups::Query, la stessa del canale CLI: ordine,
        # filtro di stato e preload dell'assegnatario in un punto solo (qui mancava, ed era l'N+1).
        records, meta = paginate(::Errors::Groups::Query.call(project: Current.project, status: params[:status]))
        render_ok(ErrorGroupSerializer.new(records), meta: meta)
      end

      def show
        group = Current.project.error_groups.find(params[:id])
        render_ok(ErrorGroupSerializer.new(group))
      end
    end
  end
end
