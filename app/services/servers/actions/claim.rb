# frozen_string_literal: true

module Servers
  module Actions
    class Claim < ApplicationService
      LEASE = 2.minutes

      def initialize(host:, now: Time.current)
        @host = host
        @now = now
      end

      def call
        # CYRA-809 — l'agent al ritorno è la prima delle due strade che chiudono un'azione rimasta a
        # metà (l'altra è il giro periodico): qui si tolgono di mezzo quelle ormai fuori tempo, con
        # l'esito che spetta a ciascuna. La regola sta scritta in un posto solo, in Reconcile, e
        # questo è fuori dalla transazione perché manda broadcast.
        Servers::Actions::Reconcile.call(host: @host, now: @now)

        action = nil
        ApplicationRecord.transaction do
          # Il recupero DENTRO la finestra di autorizzazione: la lease è scaduta ma l'azione può
          # ancora essere consegnata, quindi torna in coda. Oltre la finestra non si ripete niente —
          # se ne è già occupata Reconcile, dichiarandola interrotta.
          @host.actions.status_running.where(lease_expires_at: ..@now, expires_at: @now..)
               .update_all(status: Servers::Action.statuses[:queued], started_at: nil, lease_expires_at: nil)
          action = @host.actions.status_queued.where(expires_at: @now..).order(:created_at).lock.first
          action&.update!(status: :running, started_at: @now, lease_expires_at: @now + LEASE)
        end
        # Chi ha lanciato l'azione sta guardando la pagina: senza questo, "in attesa" diventa "in
        # corso" solo al push successivo dell'agent, cioè fino a un minuto dopo che è già partita.
        # Fuori dalla transazione, come gli altri broadcast del dominio.
        Servers::Broadcast.refresh(@host) if action
        Result.ok(action)
      end
    end
  end
end
