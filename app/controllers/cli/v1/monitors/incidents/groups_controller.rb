# frozen_string_literal: true

module Cli
  module V1
    module Monitors
      module Incidents
        # Unificazione (grouping) degli incident di un monitor + primo step della narrazione (create,
        # collection bulk su incident_ids), e scioglimento del raggruppamento (destroy, member sul
        # primary). Gate `uptime.manage` (scope progetto). Logica nei service condivisi
        # Uptime::Incidents::{GroupAndUpdate,Ungroup}. Specchio di Member::Monitoring::Incidents::GroupsController.
        class GroupsController < Cli::V1::BaseController
          before_action :set_project!
          before_action :set_monitor
          before_action -> { require_permission!("uptime.manage", scope: @project) }

          # POST collection: unifica gli incident selezionati e posta il primo step.
          def create
            result = ::Uptime::Incidents::GroupAndUpdate.call(
              monitor: @monitor, incident_ids: params[:incident_ids], phase: params[:phase],
              body: params[:body], actor: Current.account
            )
            if result.ok?
              render_created(IncidentSerializer.new(result.value))
            else
              render_error(result.error.code, result.error.message,
                           status: result.error.status, details: result.error.details)
            end
          end

          # DELETE member (:id = incident primary): scioglie il raggruppamento (i figli tornano separati).
          # keep_incident_id = la finestra che conserva lo status (narrazione).
          def destroy
            incident = @monitor.incidents.top_level.find(params[:id])
            ::Uptime::Incidents::Ungroup.call(
              incident: incident, keep_incident_id: params[:keep_incident_id], actor: Current.account
            )
            render_no_content
          end

          private

          def set_monitor
            @monitor = @project.uptime_monitors.find(params[:monitor_id])
          end
        end
      end
    end
  end
end
