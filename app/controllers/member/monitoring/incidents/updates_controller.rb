# frozen_string_literal: true

module Member
  module Monitoring
    module Incidents
      # Step successivi della timeline di un incident narrato (create) ed eliminazione di uno step
      # (destroy). Il primo step si crea via GroupsController#create. Gate uptime.manage; anti-BOLA.
      class UpdatesController < Member::BaseController
        before_action :set_monitor
        before_action :require_uptime
        before_action :set_incident

        def create
          result = ::Uptime::Incidents::AddUpdate.call(
            incident: @incident, phase: params[:phase], body: params[:body], actor: Current.account
          )
          if result.ok?
            redirect_to member_monitoring_monitor_path(@monitor), notice: t("member.uptime.incident.step_added")
          else
            redirect_to member_monitoring_monitor_path(@monitor), alert: result.error.message
          end
        end

        def destroy
          @incident.updates.find(params[:id]).destroy
          ::Uptime::Incidents::Broadcast.incidents(@monitor)
          redirect_to member_monitoring_monitor_path(@monitor), notice: t("member.uptime.incident.step_deleted")
        end

        private

        def set_monitor
          @monitor = visible.monitors.includes(project: :organization).find(params[:monitor_id])
        end

        def require_uptime
          require_permission!("uptime.manage", scope: @monitor.project)
        end

        # Gli update vivono sul primary (top-level): un incident_id figlio → 404.
        def set_incident
          @incident = @monitor.incidents.top_level.find(params[:incident_id])
        end
      end
    end
  end
end
