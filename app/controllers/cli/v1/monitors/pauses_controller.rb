# frozen_string_literal: true

module Cli
  module V1
    module Monitors
      # Pausa del monitor come sub-resource singleton: PUT = metti in pausa, DELETE = riprendi.
      # Gate `uptime.manage` (scope = progetto del path). Mutazione semplice (toggle `active`), nessun
      # service dedicato a monte nel canale Member: qui resta inline come la UI (pause/resume).
      class PausesController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_monitor

        def update
          return unless require_permission!("uptime.manage", scope: @project)

          @monitor.update!(active: false)
          render_ok(MonitorSerializer.new(@monitor))
        end

        def destroy
          return unless require_permission!("uptime.manage", scope: @project)

          @monitor.update!(active: true)
          render_ok(MonitorSerializer.new(@monitor))
        end

        private

        # Anti-BOLA: monitor dentro @project (già ristretto a visible_projects) → fuori scope = R404.
        def set_monitor
          @monitor = @project.uptime_monitors.find(params[:monitor_id])
        end
      end
    end
  end
end
