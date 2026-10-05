# frozen_string_literal: true

module Cli
  module V1
    # Gruppi-metrica (query/metodi lenti) del progetto (lettura). Visibilità = gate.
    class MetricGroupsController < Cli::V1::BaseController
      before_action :set_project!
      # CYRA-45: il triage bulk muta lo stato → gate metrics.promote (unica chiave di gestione metriche).
      before_action -> { require_permission!("metrics.promote", scope: @project) }, only: :bulk_triage

      def index
        # CYRA-738 — stessa domanda ai dati del canale API (Metrics::Groups::Query).
        records, meta = paginate(::Metrics::Groups::Query.call(project: @project, kind: params[:kind]))
        render_ok(MetricGroupSerializer.new(records), meta: meta)
      end

      def show
        group = @project.metric_groups.find(params[:id])
        render_ok(MetricGroupSerializer.new(group))
      end

      # CYRA-45: triage bulk (ids[] + bulk_action resolve/ignore/reopen) — equivalente CLI del bottone
      # bulk della lista Member. Scope = @project.metric_groups (già gattato): id fuori progetto scartati.
      def bulk_triage
        result = Metrics::BulkTriage.call(
          scope: @project.metric_groups, ids: params[:ids], action: params[:bulk_action]
        )
        return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?

        render_ok(MetricGroupSerializer.new(result.value), meta: { updated: result.value.size })
      end
    end
  end
end
