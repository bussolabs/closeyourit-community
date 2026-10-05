# frozen_string_literal: true

module Member
  module Monitoring
    module CronMonitors
      # CYRA-484 — sospendere un lavoro programmato durante una manutenzione, senza eliminarlo e senza
      # ricevere avvisi per un silenzio voluto. PUT sospende, DELETE riprende: idempotenti entrambi.
      #
      # Sospeso ≠ eliminato: il monitor resta con il suo storico e torna a controllare quando lo
      # riprendi. Riprendendo si riparte da «mai visto», non fingendo che il lavoro sia andato bene:
      # lo stato torna vero al primo check-in.
      class PausesController < Member::BaseController
        before_action :set_monitor
        before_action -> { require_permission!("uptime.manage", scope: @monitor.project) }

        def update
          @monitor.update!(enabled: false)
          redirect_to member_monitoring_cron_monitor_path(@monitor), notice: t("member.crons.paused")
        end

        def destroy
          @monitor.update!(enabled: true, status: :unknown)
          redirect_to member_monitoring_cron_monitor_path(@monitor), notice: t("member.crons.resumed")
        end

        private

        def set_monitor
          @monitor = visible.cron_monitors.find(params[:cron_monitor_id])
        end
      end
    end
  end
end
