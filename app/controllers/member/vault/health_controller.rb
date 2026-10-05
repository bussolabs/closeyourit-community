# frozen_string_literal: true

module Member
  module Vault
    # Le anomalie dei secret (CYRA-137 → riscritta in CYRA-409): quale variabile manca e in quale
    # ambiente, con da quando e la possibilità di marcarne una come «assenza voluta».
    #
    # Da CYRA-428 l'ELENCO non vive più qui: è confluito nella lista unica di «Da sistemare»
    # (Member::Vault::AttentionController), che raccoglie anomalie, rotazioni e richieste ordinate per
    # rischio. `index` resta come indirizzo — chi ce l'ha nei segnalibri arriva alla pagina nuova — e
    # non porta gate: un redirect non espone nulla, e il permesso lo applica la destinazione (dove il
    # gate è composto, quindi più largo di questo).
    #
    # Restano qui le AZIONI, che cambiano una decisione umana: marcare e annullare l'assenza voluta,
    # gated secrets_audit.view e anti-BOLA sul progetto visibile.
    class HealthController < Member::BaseController
      permission_not_required "Vecchio indirizzo che rimanda alla lista unica: il permesso lo applica la " \
                              "destinazione.",
                              only: %i[index]

      before_action :require_health_view, except: :index
      before_action :set_anomaly, only: %i[acknowledge restore]

      def index
        redirect_to member_vault_attention_path
      end

      # Marca l'anomalia come «assenza voluta»: esce dai conteggi ma resta consultabile, con CHI l'ha
      # decisa e QUANDO (la decisione vale per il progetto/organizzazione — risposta del cliente su
      # CYRA-409). La nota è obbligatoria: senza motivazione non è una decisione, è solo silenziare.
      def acknowledge
        reason = params[:reason].to_s.strip
        if reason.blank?
          return redirect_to member_vault_attention_path, alert: t("member.vault_health.acknowledge_needs_reason")
        end

        @anomaly.update!(status: :acknowledged, acknowledged_at: Time.current,
                         acknowledged_by: Current.account, acknowledgement_reason: reason)
        redirect_to member_vault_attention_path, notice: t("member.vault_health.acknowledged")
      end

      # Annulla la decisione: l'assenza torna fra le anomalie da guardare (open), la nota viene rimossa.
      def restore
        @anomaly.update!(status: :open, acknowledged_at: nil, acknowledged_by: nil,
                         acknowledgement_reason: nil, resolved_at: nil)
        redirect_to member_vault_attention_path, notice: t("member.vault_health.restored")
      end

      private

      def require_health_view
        require_permission!("secrets_audit.view")
      end

      # Anti-BOLA: l'anomalia dev'essere di un progetto VISIBILE all'account, non basta esistere nel DB
      # → 404 su progetto invisibile/altra org (stesso pattern di ChangeRequestsController#set_change_request).
      def set_anomaly
        @anomaly = ::Secrets::HealthAnomaly.where(project_id: visible.projects.select(:id))
                                            .find(params[:id])
      end
    end
  end
end
