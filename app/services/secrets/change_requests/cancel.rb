# frozen_string_literal: true

module Secrets
  module ChangeRequests
    # Ritira una Secrets::ChangeRequest pending (CYRA-138, Fase 4 pezzo C2a — SERVICE DI DECISIONE):
    # SOLO chi l'ha richiesta può cambiare idea e ritirarla — è l'inverso del vincolo 4-eyes di
    # Approve/Reject (lì "chi decide ≠ chi ha chiesto", qui "solo chi ha chiesto può decidere di
    # ritirare"), quindi riusa il predicato DecisionGuard#requester? con polarità invertita ma ha un
    # proprio errore dedicato (R403-CHANGEREQUEST-002, codice/testo diversi da self_decision).
    #
    # Nessuna applicazione: il secret non cambia mai, la richiesta si congela come `cancelled`.
    class Cancel < ApplicationService
      include DecisionGuard

      def initialize(change_request:, actor:)
        @change_request = change_request
        @actor = actor
      end

      def call
        ApplicationRecord.transaction do
          @change_request.lock!
          return stale if stale?
          return not_requester unless requester?

          @change_request.update!(status: :cancelled, decided_by: @actor, decided_at: Time.current)
        end

        Result.ok(@change_request)
      end

      private

      def not_requester
        Result.err(AppError.new("Solo chi ha fatto la richiesta può ritirarla", code: "R403-CHANGEREQUEST-002",
                                 status: :forbidden))
      end
    end
  end
end
