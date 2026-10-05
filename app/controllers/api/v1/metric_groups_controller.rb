# frozen_string_literal: true

module Api
  module V1
    # Lettura dei gruppi-metrica del progetto del token (bearer). Scoping al solo Current.project
    # (il token pinna un progetto) → anti-BOLA implicito.
    class MetricGroupsController < Api::V1::BaseController
      # La lettura della telemetria richiede lo scope 'read' (CYRA-37): un token ingest-only → 403.
      before_action -> { require_scope!(:read) }

      def index
        # CYRA-738 — stessa domanda ai dati del canale CLI (Metrics::Groups::Query).
        records, meta = paginate(::Metrics::Groups::Query.call(project: Current.project, kind: params[:kind]))
        render_ok(MetricGroupSerializer.new(records), meta: meta)
      end

      def show
        group = Current.project.metric_groups.find(params[:id])
        render_ok(MetricGroupSerializer.new(group))
      end
    end
  end
end
