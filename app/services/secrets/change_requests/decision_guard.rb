# frozen_string_literal: true

module Secrets
  module ChangeRequests
    # Guardie condivise dai service di DECISIONE su una Secrets::ChangeRequest (Approve/Reject/Cancel —
    # CYRA-138, Fase 4 pezzo C2a). Pattern gemello di Agents::Workflows::CtoGate: predicati + errori di
    # dominio riusati da più service dello stesso mini-workflow, mai duplicati.
    #
    # - stale?/stale: idempotenza — una CR non più `pending` (già applied/rejected/cancelled) non è
    #   ridecidibile una seconda volta: R409 (conflitto), mai un no-op silenzioso.
    # - requester?/self_decision: vincolo 4-eyes di separazione — chi DECIDE (Approve/Reject) non può
    #   essere chi ha CHIESTO. Cancel riusa il predicato `requester?` con polarità INVERTITA (solo il
    #   richiedente PUÒ ritirare) e ha un errore dedicato (R403-CHANGEREQUEST-002, messaggio diverso) —
    #   non condiviso qui perché il codice/testo cambia.
    # - human_actor?/machine_decision (CYRA-640): la decisione la prende una PERSONA. Il 4-eyes da solo
    #   non lo garantisce — chiede solo un attore DIVERSO dal richiedente, e un account di servizio
    #   (Accounts::Account kind: :service) con `secrets.manage` è un attore diverso: superava il guard e
    #   chiudeva da solo il secondo passaggio, che esiste apposta per mettere un umano fra una modifica
    #   ai secret di un ambiente protetto e la sua applicazione. Il canale CLI è la porta reale: un
    #   service account non fa login web (Auth::SessionsController esige `human?`) ma il suo token
    #   `cyi_u_` si autentica come quello di una persona (UserTokenAuthentication non guarda `kind`).
    #   Il guard sta qui — nel service, non nei controller — perché i canali che decidono sono tre
    #   (web vault, feed «Da sistemare», CLI) e uno solo dimenticato riapre la falla.
    #   Fail-closed: attore assente = non umano. Vale per Approve/Reject, NON per Cancel — ritirare la
    #   propria richiesta non scavalca niente (il secret non cambia) e una macchina deve poter rinunciare
    #   a ciò che ha chiesto, altrimenti la CR resta pending finché un umano non la rifiuta.
    module DecisionGuard
      private

      def environment_allowed?
        ::Secrets::EnvironmentAccess.new(account: @actor, project: @change_request.project)
          .allowed?(@change_request.environment.code)
      end

      def forbidden_environment
        Rails.logger.warn("Secret change request environment denied actor_id=#{@actor.id} request_id=#{@change_request.id}")
        Result.err(AppError.new("This account cannot decide changes in this environment",
                                code: "R403-CHANGEREQUEST-004", status: :forbidden))
      end

      def stale?
        !@change_request.pending?
      end

      def stale
        Result.err(AppError.new("La richiesta è già stata decisa", code: "R409-CHANGEREQUEST-001", status: :conflict))
      end

      def requester?
        @actor.id == @change_request.requested_by_id
      end

      def self_decision
        Result.err(AppError.new("Non puoi decidere la tua stessa richiesta", code: "R403-CHANGEREQUEST-001",
                                 status: :forbidden))
      end

      def human_actor?
        @actor.present? && @actor.human?
      end

      def machine_decision
        Result.err(AppError.new("Solo una persona può approvare o rifiutare: un account di servizio non " \
                                "può decidere una richiesta di modifica ai segreti",
                                code: "R403-CHANGEREQUEST-003", status: :forbidden))
      end
    end
  end
end
