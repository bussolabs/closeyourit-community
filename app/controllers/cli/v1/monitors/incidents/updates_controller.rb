# frozen_string_literal: true

module Cli
  module V1
    module Monitors
      module Incidents
        # Step successivi della timeline di un incident narrato (create) ed eliminazione di uno step
        # (destroy), via CLI. Il primo step si crea via GroupsController#create. Gate `uptime.manage`
        # (scope progetto). Gli update vivono sul primary (top_level): un incident_id figlio → R404.
        # Specchio di Member::Monitoring::Incidents::UpdatesController.
        class UpdatesController < Cli::V1::BaseController
          before_action :set_project!
          before_action :set_monitor
          before_action -> { require_permission!("uptime.manage", scope: @project) }
          before_action :set_incident

          def create
            result = ::Uptime::Incidents::AddUpdate.call(
              incident: @incident, phase: params[:phase], body: params[:body], actor: Current.account
            )
            if result.ok?
              render_created(IncidentUpdateSerializer.new(result.value))
            else
              render_error(result.error.code, result.error.message,
                           status: result.error.status, details: result.error.details)
            end
          end

          def destroy
            @incident.updates.find(params[:id]).destroy
            ::Uptime::Incidents::Broadcast.incidents(@monitor)
            render_no_content
          end

          private

          def set_monitor
            @monitor = @project.uptime_monitors.find(params[:monitor_id])
          end

          # Gli update vivono sul primary (top_level): un incident_id figlio → RecordNotFound → R404.
          def set_incident
            @incident = @monitor.incidents.top_level.find(params[:incident_id])
          end
        end
      end
    end
  end
end
