# frozen_string_literal: true

module Accounts
  module Service
    # "Elimina" un service account dall'org PRESERVANDONE l'identità per l'audit: revoca ogni accesso
    # (chiavi + RBAC + team + preferenze + membership) via Connections::RevokeOrgAccess, ma la riga
    # `Accounts::Account` NON viene distrutta.
    #
    # Perché non `account.destroy`: la chiave esterna di `secrets_events.actor_id` è `on_delete:
    # :nullify` → una destroy fisica azzererebbe `Secrets::Event.actor_id`, e l'audit dei secret
    # perderebbe l'identità dell'agente che ha letto/scritto i valori (mostrerebbe "system").
    # L'hard-delete resta possibile solo dal pannello god (scelta deliberata, con la perdita di
    # audit che comporta).
    #
    # La meccanica di revoca (ordine token→accesso→membership, transazione, rollback) vive in
    # Connections::RevokeOrgAccess, condivisa con la rimozione di un membro umano (CYRA-241).
    class Retire < ApplicationService
      def initialize(account:, organization:)
        @account = account
        @organization = organization
      end

      def call
        # invalid_code preserva il contratto d'errore storico dei service account (i client CLI lo
        # distinguono) sul fallback RecordInvalid della revoca.
        Connections::RevokeOrgAccess.call(account: @account, organization: @organization,
                                          invalid_code: "R422-SERVICEACCOUNT-002")
      end
    end
  end
end
