# frozen_string_literal: true

module Member
  module Monitoring
    class ServerActionsController < Member::BaseController
      # CYRA-737 — la base condivisa dell'area di controllo. Qui non c'è una lista da paginare: resta
      # inerte, e serve a far nascere già sulla base comune la prossima cosa che si aggiunge.
      include Indexable

      before_action -> { require_permission!("servers.execute") }
      before_action :set_host

      def create
        unless ActiveSupport::SecurityUtils.secure_compare(params[:confirmation].to_s, @host.name)
          return redirect_to(member_monitoring_server_path(@host, tab: "operations"), alert: t("member.servers.action_queue.confirmation_invalid"))
        end
        unless @host.host_tokens.active.exists?
          return redirect_to(member_monitoring_server_path(@host, tab: "operations"), alert: t("member.servers.action_queue.agent_upgrade_required"))
        end
        # La view nasconde le azioni che l'agent installato non conosce, ma il gate vive qui: senza,
        # una POST diretta accoderebbe un'azione che l'host può solo rifiutare, e resterebbe appesa
        # bloccando l'unica slot attiva per host (indice parziale su queued|running).
        unless @host.supports_action?(params[:kind].to_s)
          return redirect_to(member_monitoring_server_path(@host, tab: "operations"), alert: t("member.servers.action_queue.agent_upgrade_required"))
        end

        @host.actions.create!(organization: Current.organization, requested_by: Current.account,
                              kind: params[:kind], idempotency_key: SecureRandom.uuid, expires_at: 1.hour.from_now)
        redirect_to member_monitoring_server_path(@host, tab: "operations"), notice: t("member.servers.action_queue.created")
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        redirect_to member_monitoring_server_path(@host, tab: "operations"), alert: e.message
      end

      def destroy
        action = @host.actions.status_queued.find(params[:id])
        action.update!(status: :cancelled, finished_at: Time.current)
        redirect_to member_monitoring_server_path(@host, tab: "operations"), notice: t("member.servers.action_queue.cancelled")
      end

      private

      def set_host = @host = visible.servers.find(params[:server_id])
    end
  end
end
