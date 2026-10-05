# frozen_string_literal: true

module Secrets
  module Notifications
    # Notifica asincrona di un evento sulla richiesta di approvazione a due (CYRA-138, Fase 4 pezzo
    # C2c): enqueued esplicitamente da Secrets::ChangeRequests::Submit (dopo il create! della CR) e da
    # Approve/Reject (dopo l'update! di stato) — mai after_commit, stesso motivo di DeletedNotifyJob
    # (Solid Queue vive su un DB separato dal primary, un enqueue in transazione girerebbe prima del
    # commit comunque). Riceve SOLO l'id della CR + il nome dell'evento (mai l'oggetto, per restare
    # serializzabile con primitivi) e la ricarica: find_by, non find!, perché Submit può girare dentro
    # la transazione di Secrets::Rows::Save — se la riga fa rollback (un'altra colonna della stessa
    # riga fallisce dopo aver creato la CR) il job trova la CR assente e resta un no-op silenzioso, mai
    # un errore.
    #
    # UN solo job parametrizzato per i 3 eventi (requested/approved/rejected), non tre job distinti:
    # stesso identico envelope (change_request_id + event), la sola differenza è quale dispatch
    # invocare.
    class ChangeRequestNotifyJob < ApplicationJob
      queue_as :notifications

      DISPATCH_FOR_EVENT = {
        "requested" => Secrets::Notifications::DispatchChangeRequested,
        "approved" => Secrets::Notifications::DispatchChangeApproved,
        "rejected" => Secrets::Notifications::DispatchChangeRejected
      }.freeze

      def perform(change_request_id:, event:)
        change_request = Secrets::ChangeRequest.find_by(id: change_request_id)
        return if change_request.nil?

        dispatch = DISPATCH_FOR_EVENT[event.to_s]
        return if dispatch.nil?

        dispatch.call(change_request: change_request)
      end
    end
  end
end
