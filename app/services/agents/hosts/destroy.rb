# frozen_string_literal: true

module Agents
  module Hosts
    # CYRA-516 — Elimina definitivamente una macchina dismessa. Non è la revoca (Revoke, che stacca le
    # credenziali ma lascia la riga in elenco per sempre): qui la riga sparisce. Revoca comunque PRIMA,
    # perché una macchina ancora accesa deve smettere di essere autorizzata prima di perdere l'identità.
    # L'ordine di cancellazione è imposto dalle FK: clarification e piani puntano all'attempt
    # (on_delete: :restrict), gli attempt all'host (restrict, e `host_id` è NOT NULL) — lo storico non
    # si può staccare dalla macchina, quindi o scende con lei o la riga resta in eterno.
    class Destroy < ApplicationService
      # Quanto storico verrebbe perso: serve PRIMA di premere (la conferma lo dice) e dopo (il flash lo
      # ripete). Un metodo solo perché i due numeri non possano divergere.
      def self.history_size(host)
        attempt_ids = ::Agents::Attempt.where(host_id: host.id).select(:id)
        {
          attempts: ::Agents::Attempt.where(host_id: host.id).count,
          plans: ::Agents::Plan.where(attempt_id: attempt_ids).count,
          clarifications: ::Agents::Clarification.where(attempt_id: attempt_ids).count
        }
      end

      def initialize(host:) = @host = host

      def call
        return busy_error if working?

        counts = self.class.history_size(@host)
        hostname = @host.hostname
        ActiveRecord::Base.transaction do
          Revoke.call(host: @host)
          attempt_ids = ::Agents::Attempt.where(host_id: @host.id).pluck(:id)
          ::Agents::Clarification.where(attempt_id: attempt_ids).delete_all
          ::Agents::Plan.where(attempt_id: attempt_ids).delete_all
          ::Agents::Attempt.where(host_id: @host.id).delete_all
          @host.destroy!
        end
        Result.ok(counts.merge(hostname:))
      end

      private

      # "Sta lavorando" = ha un lease ANCORA VALIDO, non un attempt in stato `running`: una macchina
      # spenta lascia i suoi lavori aperti a database perché nessuno li chiude (è il caso descritto in
      # CYRA-498), e prendendo quelli per lavoro vivo non sarebbe mai eliminabile.
      def working?
        @host.leases.where(expires_at: ::Agents::Leases::Clock.current..).exists?
      end

      def busy_error
        Result.err(AppError.new("Host has work in progress", code: "R422-AGENT-008"))
      end
    end
  end
end
