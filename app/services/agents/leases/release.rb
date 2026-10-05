# frozen_string_literal: true

module Agents
  module Leases
    class Release < Operation
      def call
        validation = prepare
        return validation if validation

        Agents::Lease.transaction do
          next forbidden_host unless lock_active_holder
          next ticket_not_found unless lock_ticket
          next Result.ok(true) if tombstoned?

          lease = Agents::Lease.lock.find_by(ticket: @ticket)
          next not_found unless lease

          now = Agents::Leases::Clock.current
          unless lease.active_at?(now)
            retire(lease, released_at: now)
            next not_found
          end
          next conflict(lease) unless owned?(lease)

          retire(lease, released_at: now)
          Result.ok(true)
        end
      end

      private

      def owned?(lease) = lease.held_by?(@holder) && lease.run_id == @params[:run_id]
    end
  end
end
