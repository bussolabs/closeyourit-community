# frozen_string_literal: true

module Secrets
  module ChangeRequests
    # Rifiuta una Secrets::ChangeRequest pending (CYRA-138, Fase 4 pezzo C2a — SERVICE DI DECISIONE):
    # NON applica nulla al secret (a differenza di Approve) — il valore reale resta esattamente quello
    # di prima, la richiesta si congela come `rejected` col motivo per l'audit.
    #
    # `reason` è OBBLIGATORIA (normalizzata con strip): un rifiuto senza spiegazione lascerebbe il
    # richiedente senza contesto per correggere e ripresentare. Stessi vincoli di Approve su chi decide —
    # 4-eyes (chi decide non può essere chi ha chiesto) e vincolo umano (CYRA-640: rifiutare CONGELA la
    # richiesta come `rejected`, non più ridecidibile, quindi una macchina che rifiuta chiude una
    # pratica che nessuna persona ha mai visto) — e stesso guard stale (DecisionGuard, pattern gemello
    # di Agents::Workflows::RequestPlanChanges: input guard PRIMA della transazione, guard sullo stato
    # PRESO IN LOCK dentro la transazione). Il vincolo umano precede anche il controllo del motivo: è
    # una decisione su CHI sta chiamando, non su cosa ha mandato.
    class Reject < ApplicationService
      include DecisionGuard

      def initialize(change_request:, actor:, reason:)
        @change_request = change_request
        @actor = actor
        @reason = reason.to_s.strip
      end

      def call
        return machine_decision unless human_actor?
        return invalid_reason if @reason.blank?

        ApplicationRecord.transaction do
          @change_request.lock!
          return stale if stale?
          return self_decision if requester?
          return forbidden_environment unless environment_allowed?

          @change_request.update!(status: :rejected, decided_by: @actor, decided_at: Time.current, reason: @reason)
        end

        enqueue_change_request_notification(event: "rejected")
        Result.ok(@change_request)
      end

      private

      def invalid_reason
        Result.err(AppError.new("Il motivo del rifiuto è obbligatorio", code: "R422-CHANGEREQUEST-001"))
      end

      # Notifica al richiedente (CYRA-138, Fase 4 pezzo C2c): SOLO dopo un rifiuto riuscito — questa
      # riga non è mai raggiunta sui rami motivo-assente/stale/self_decision (return prima o dentro la
      # transazione). Mai after_commit, stesso motivo di Submit/Approve.
      def enqueue_change_request_notification(event:)
        ::Secrets::Notifications::ChangeRequestNotifyJob.perform_later(
          change_request_id: @change_request.id, event: event
        )
      end
    end
  end
end
