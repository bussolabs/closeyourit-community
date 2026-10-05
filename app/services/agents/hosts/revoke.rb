# frozen_string_literal: true

module Agents
  module Hosts
    # Revoca idempotentemente l'installazione e tutte le sue credenziali ancora attive. Segue il
    # suffisso host → ticket → lease dell'ordine globale del dispatch; non risale mai a organization.
    class Revoke < ApplicationService
      def initialize(host:) = @host = host

      def call
        @host.with_lock do
          now = Agents::Leases::Clock.current
          @host.update!(revoked_at: now) unless @host.revoked?
          @host.host_tokens.active.update_all(revoked_at: now, updated_at: now)
          release_leases(now)
        end
        Result.ok(@host)
      end

      private

      def release_leases(now)
        ticket_ids = @host.leases.reorder(:ticket_id).distinct.pluck(:ticket_id)
        Ticketing::Ticket.where(id: ticket_ids).order(:id).lock.each do |ticket|
          lease = Agents::Lease.lock.find_by(ticket:, host: @host)
          next unless lease

          Agents::Leases::Tombstone.record!(lease:, released_at: now)
          lease.destroy!
        end
      end
    end
  end
end
