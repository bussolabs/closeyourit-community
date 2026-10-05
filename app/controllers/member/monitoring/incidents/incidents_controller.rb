# frozen_string_literal: true

module Member
  module Monitoring
    module Incidents
      # Eliminazione definitiva di un incident intero (+ finestre unificate figlie, cascade nel service).
      # Gate uptime.manage; anti-BOLA via visible.monitors + top_level.find (un incident figlio → 404).
      class IncidentsController < Member::BaseController
        before_action :set_monitor
        before_action :require_uptime
        before_action :set_incident

        def destroy
          ::Uptime::Incidents::Delete.call(incident: @incident, actor: Current.account)
          redirect_to member_monitoring_monitor_path(@monitor), notice: t("member.uptime.incident.deleted")
        end

        private

        def set_monitor
          @monitor = visible.monitors.includes(project: :organization).find(params[:monitor_id])
        end

        def require_uptime
          require_permission!("uptime.manage", scope: @monitor.project)
        end

        # Solo i primary (top-level) sono eliminabili da qui: un incident figlio → 404.
        def set_incident
          @incident = @monitor.incidents.top_level.find(params[:id])
        end
      end
    end
  end
end
