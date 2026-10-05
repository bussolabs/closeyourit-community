# frozen_string_literal: true

module Cli
  module V1
    module Monitors
      # Eliminazione definitiva di un incident intero (+ finestre unificate figlie, cascade nel service),
      # via CLI. Gate `uptime.manage` (scope progetto). Solo i primary (top_level) sono eliminabili: un
      # incident figlio → R404. Specchio di Member::Monitoring::Incidents::IncidentsController.
      class IncidentsController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_monitor
        before_action -> { require_permission!("uptime.manage", scope: @project) }

        def destroy
          incident = @monitor.incidents.top_level.find(params[:id])
          ::Uptime::Incidents::Delete.call(incident: incident, actor: Current.account)
          render_no_content
        end

        private

        # Anti-BOLA: monitor dentro @project (visible_projects) → fuori scope = R404.
        def set_monitor
          @monitor = @project.uptime_monitors.find(params[:monitor_id])
        end
      end
    end
  end
end
