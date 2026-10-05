# frozen_string_literal: true

module Member
  module Monitoring
    module Incidents
      # Unificazione degli incident di un monitor (grouping) + primo step della timeline (create),
      # e scioglimento del raggruppamento (destroy). Thin adapter sul dominio Uptime::Incidents::*.
      # Gate uptime.manage sul progetto del monitor; anti-BOLA via visible.monitors (404).
      class GroupsController < Member::BaseController
        before_action :set_monitor
        before_action :require_uptime

        # POST .../incidents/group — unifica gli incident selezionati e posta il primo step.
        def create
          result = ::Uptime::Incidents::GroupAndUpdate.call(
            monitor: @monitor, incident_ids: params[:incident_ids], phase: params[:phase],
            body: params[:body], actor: Current.account
          )
          if result.ok?
            redirect_to member_monitoring_monitor_path(@monitor), notice: t("member.uptime.incident.grouped")
          else
            redirect_to member_monitoring_monitor_path(@monitor), alert: result.error.message
          end
        end

        # DELETE .../incidents/:incident_id/group — scioglie il raggruppamento (i figli tornano separati).
        # keep_incident_id = la finestra (primary o un figlio) che conserva lo status (narrazione).
        def destroy
          incident = @monitor.incidents.top_level.find(params[:incident_id])
          ::Uptime::Incidents::Ungroup.call(
            incident:, keep_incident_id: params[:keep_incident_id], actor: Current.account
          )
          redirect_to member_monitoring_monitor_path(@monitor), notice: t("member.uptime.incident.ungrouped")
        end

        private

        def set_monitor
          @monitor = visible.monitors.includes(project: :organization).find(params[:monitor_id])
        end

        def require_uptime
          require_permission!("uptime.manage", scope: @monitor.project)
        end
      end
    end
  end
end
