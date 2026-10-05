# frozen_string_literal: true

module Cli
  module V1
    # Cron/heartbeat monitor (sola lettura, canale CLI). Scope = monitor dei progetti VISIBILI (nessuna
    # chiave RBAC: read = visibilità, come logs/errors). Nascono dai check-in via API, non si creano da
    # CLI. Filtri opzionali ?status (enum) e ?project_id (risolto nello scope visibile → R404 anti-BOLA).
    class CronMonitorsController < Cli::V1::BaseController
      before_action :set_monitor, only: :show

      def index
        records, meta = paginate(filtered(scoped_monitors.recent))
        render_ok(CronMonitorSerializer.new(records), meta: meta)
      end

      def show
        render_ok(CronMonitorSerializer.new(@monitor))
      end

      private

      def scoped_monitors
        Crons::Monitor.where(project_id: visible_projects.select(:id)).includes(:project, :environment)
      end

      def filtered(scope)
        scope = scope.where(status: params[:status]) if Crons::Monitor.statuses.key?(params[:status])
        scope = scope.where(project_id: visible_projects.find(params[:project_id]).id) if params[:project_id].present?
        scope
      end

      def set_monitor
        @monitor = scoped_monitors.find(params[:id])
      end
    end
  end
end
