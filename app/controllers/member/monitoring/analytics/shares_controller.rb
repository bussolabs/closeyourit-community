# frozen_string_literal: true

module Member
  module Monitoring
    module Analytics
      # Crea/revoca il link pubblico di condivisione (embed) della dashboard analytics di un progetto.
      # Un link attivo per progetto (v1). Anti-BOLA via lo scope visibile+collecting.
      #
      # CYRA-697 — il gate `analytics.share.manage` è la METÀ MANCANTE: `set_project` dice QUALE
      # progetto, non SE puoi. Senza chiave chiunque vedesse un progetto che raccoglie statistiche —
      # una membership `customer` esterna compresa — pubblicava su internet la dashboard di traffico
      # con una sola richiesta, e in banca dati non restava scritto chi fosse stato.
      class SharesController < Member::BaseController
        before_action :set_project
        before_action -> { require_permission!("analytics.share.manage", scope: @project) }

        def create
          ::Analytics::Links::Create.call(project: @project, password: params[:password].presence,
                                          actor: Current.account)
          redirect_to dashboard_path, notice: t("member.monitoring.analytics.share.created")
        end

        def destroy
          link = @project.analytics_links.active.first
          ::Analytics::Links::Revoke.call(link: link) if link
          redirect_to dashboard_path, notice: t("member.monitoring.analytics.share.revoked")
        end

        private

        def dashboard_path
          member_monitoring_analytics_path(project_id: @project.id)
        end

        def set_project
          @project = visible.projects.analytics_collecting.find(params[:project_id])
        end
      end
    end
  end
end
