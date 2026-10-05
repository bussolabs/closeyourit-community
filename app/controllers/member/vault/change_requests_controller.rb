# frozen_string_literal: true

module Member
  module Vault
    # Le richieste di modifica ai segreti in attesa dell'approvazione a due (CYRA-138, Fase 4 pezzo
    # C2b). Da CYRA-428 l'ELENCO vive dentro la lista unica di «Da sistemare»
    # (Member::Vault::AttentionController), insieme ad anomalie e rotazioni: `index` resta come
    # indirizzo e ci porta, senza gate — un redirect non espone nulla e il permesso lo applica la
    # destinazione, dove il gate composto (vault_change_requests_nav_visible?) è lo stesso di prima.
    #
    # Le azioni (approve/reject/cancel) restano qui e risolvono la CR dentro visible.projects
    # (anti-BOLA → 404 su progetto invisibile/altra org). approve/reject sono gated secrets.manage sul
    # progetto della CR (il service C2a ri-applica il vincolo 4-eyes come difesa in profondità);
    # cancel NON ha gate di permesso — solo il richiedente supera il guard del service (R403 altrimenti).
    class ChangeRequestsController < Member::BaseController
      permission_not_required "L'elenco rimanda alla lista unica; annullare la propria richiesta lo verifica il " \
                              "service che la annulla.",
                              only: %i[index cancel]

      before_action :set_change_request, only: %i[approve reject cancel]
      before_action :require_manage_permission, only: %i[approve reject]

      def index
        redirect_to member_vault_attention_path
      end

      def approve
        result = ::Secrets::ChangeRequests::Approve.call(change_request: @change_request, actor: Current.account)
        redirect_after_decision(result, notice: t("member.vault_change_requests.approved", name: @change_request.name))
      end

      def reject
        result = ::Secrets::ChangeRequests::Reject.call(
          change_request: @change_request, actor: Current.account, reason: params[:reason]
        )
        redirect_after_decision(result, notice: t("member.vault_change_requests.rejected", name: @change_request.name))
      end

      def cancel
        result = ::Secrets::ChangeRequests::Cancel.call(change_request: @change_request, actor: Current.account)
        redirect_after_decision(result, notice: t("member.vault_change_requests.cancelled", name: @change_request.name))
      end

      private

      # Anti-BOLA: la CR dev'essere di un progetto VISIBILE all'account (come set_project altrove),
      # non basta esistere nel DB → 404 su progetto invisibile/altra org. Vale per TUTTE e tre le
      # azioni, incluso cancel (che non ha un gate di permesso: il service C2a verifica da solo che
      # l'attore sia il richiedente, ma la RISOLUZIONE della CR resta comunque anti-BOLA).
      def set_change_request
        @change_request = ::Secrets::ChangeRequest.where(project_id: visible.projects.select(:id))
                                                    .find(params[:id])
      end

      # Solo approve/reject (before_action only: %i[approve reject]): cancel lo salta, il service C2a
      # verifica da solo che l'attore sia il richiedente.
      def require_manage_permission
        require_permission!("secrets.manage", scope: @change_request.project)
      end

      def redirect_after_decision(result, notice:)
        if result.ok?
          redirect_to member_vault_attention_path, notice: notice
        else
          redirect_to member_vault_attention_path, alert: result.error.message
        end
      end
    end
  end
end
