# frozen_string_literal: true

module Member
  module Monitoring
    module Monitors
      # Banner della status page pubblica di un monitor (manutenzioni/avvisi): create/update = upsert
      # dell'unico banner, destroy = rimozione. Gate uptime.manage; anti-BOLA via visible.monitors.
      class AnnouncementsController < Member::BaseController
        before_action :set_monitor
        before_action :require_uptime

        def create = save
        def update = save

        def destroy
          ::Uptime::Announcements::Clear.call(monitor: @monitor, actor: Current.account)
          redirect_to member_monitoring_monitor_path(@monitor, tab: "public"), notice: t("member.uptime.announcement.cleared")
        end

        private

        def save
          result = ::Uptime::Announcements::Save.call(
            monitor: @monitor, attributes: announcement_params, actor: Current.account
          )
          if result.ok?
            redirect_to member_monitoring_monitor_path(@monitor, tab: "public"), notice: t("member.uptime.announcement.saved")
          else
            redirect_to member_monitoring_monitor_path(@monitor, tab: "public"), alert: result.error.message
          end
        end

        def announcement_params
          params.permit(:level, :message, :starts_at, :ends_at, :active)
        end

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
