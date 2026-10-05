# frozen_string_literal: true

module Cli
  module V1
    # Monitor uptime del progetto: lettura (baseline, chi vede il progetto può) + gestione gated
    # `uptime.manage` (create/update/destroy, scope = progetto del path). project ed environment sono
    # immutabili dopo la creazione. La logica vive in Uptime::Monitors::Save, condivisa col canale
    # Member (`rules/backend-channels.md`): qui solo auth/gate/serializzazione del canale CLI.
    # Anti-BOLA: set_project! risolve dentro visible_projects (fuori scope → R404 prima del gate).
    class MonitorsController < Cli::V1::BaseController
      before_action :set_project!
      before_action :set_monitor, only: %i[show update destroy]

      def index
        records, meta = paginate(@project.uptime_monitors.order(:name))
        render_ok(MonitorSerializer.new(records), meta: meta)
      end

      def show
        render_ok(MonitorSerializer.new(@monitor))
      end

      def create
        return unless require_permission!("uptime.manage", scope: @project)

        result = Uptime::Monitors::Save.call(
          monitor: Uptime::Monitor.new, attributes: monitor_params,
          project: @project, environment_id: params[:environment_id], actor: Current.account, **group_id_arg
        )
        if result.ok?
          render_created(MonitorSerializer.new(result.value))
        else
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end

      def update
        return unless require_permission!("uptime.manage", scope: @project)

        result = Uptime::Monitors::Save.call(monitor: @monitor, attributes: monitor_params, **group_id_arg)
        if result.ok?
          render_ok(MonitorSerializer.new(@monitor))
        else
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end

      def destroy
        return unless require_permission!("uptime.manage", scope: @project)

        @monitor.destroy
        render_no_content
      end

      private

      # Anti-BOLA: il monitor si risolve DENTRO @project (già ristretto a visible_projects da set_project!);
      # un monitor di un altro progetto/org → RecordNotFound → R404 (mai 403, mai leak cross-tenant).
      def set_monitor
        @monitor = @project.uptime_monitors.find(params[:id])
      end

      # name escluso: è auto-derivato dal model (progetto · environment). project/environment immutabili.
      def monitor_params
        params.permit(:check_type, :url, :host, :port, :http_method, :interval_seconds, :expected_status,
                      :timeout_seconds, :expected_body_keyword, :ssl_expiry_warn_days, :latency_threshold_ms,
                      :failure_threshold)
      end

      # group_id (gruppo uptime, org-level) applicato SOLO se presente nel request: altrimenti resta il
      # sentinel :unchanged di Uptime::Monitors::Save (update parziale non azzera il gruppo assegnato).
      def group_id_arg
        params.key?(:group_id) ? { group_id: params[:group_id] } : {}
      end
    end
  end
end
