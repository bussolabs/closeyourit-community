# frozen_string_literal: true

module Cli
  module V1
    module Monitors
      # Banner della status page pubblica del monitor (manutenzioni/avvisi) come sub-resource SINGLETON:
      # GET = leggi (null se assente), PUT = upsert, DELETE = rimuovi. Gate `uptime.manage` (scope progetto),
      # come Member::Monitoring::Monitors::AnnouncementsController. Logica nei service condivisi
      # Uptime::Announcements::{Save,Clear}. Anti-BOLA: monitor dentro @project (visible_projects) → R404.
      class AnnouncementsController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_monitor
        before_action -> { require_permission!("uptime.manage", scope: @project) }

        def show
          render_ok(@monitor.announcement ? AnnouncementSerializer.new(@monitor.announcement) : nil)
        end

        def update
          result = ::Uptime::Announcements::Save.call(
            monitor: @monitor, attributes: announcement_params, actor: Current.account
          )
          if result.ok?
            render_ok(AnnouncementSerializer.new(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def destroy
          ::Uptime::Announcements::Clear.call(monitor: @monitor, actor: Current.account)
          render_no_content
        end

        private

        def announcement_params
          params.permit(:level, :message, :starts_at, :ends_at, :active)
        end

        def set_monitor
          @monitor = @project.uptime_monitors.find(params[:monitor_id])
        end
      end
    end
  end
end
