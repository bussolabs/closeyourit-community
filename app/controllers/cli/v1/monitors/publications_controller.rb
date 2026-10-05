# frozen_string_literal: true

module Cli
  module V1
    module Monitors
      # Status page pubblica (opt-in) del monitor come sub-resource singleton: PUT = pubblica,
      # DELETE = ritira. Gate `uptime.manage` (scope = progetto del path). update_column (non update!):
      # il flag pubblico è una preferenza indipendente e non dev'essere bloccata da validazioni estranee
      # — specchio di Member::Monitoring::MonitorsController#publish/#unpublish. Anti-BOLA: monitor dentro
      # @project (già ristretto a visible_projects) → fuori scope = R404.
      class PublicationsController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_monitor

        def update
          return unless require_permission!("uptime.manage", scope: @project)

          @monitor.update_column(:public_status_enabled, true)
          render_ok(MonitorSerializer.new(@monitor))
        end

        def destroy
          return unless require_permission!("uptime.manage", scope: @project)

          @monitor.update_column(:public_status_enabled, false)
          render_ok(MonitorSerializer.new(@monitor))
        end

        private

        def set_monitor
          @monitor = @project.uptime_monitors.find(params[:monitor_id])
        end
      end
    end
  end
end
