# frozen_string_literal: true

module Agents
  module Leases
    class Renew < Operation
      def call
        validation = prepare(require_ttl: true, require_scope: true)
        return validation if validation

        Agents::Lease.transaction do
          next forbidden_host unless lock_active_holder
          next ticket_not_found unless lock_ticket

          lease = Agents::Lease.lock.find_by(ticket: @ticket)
          next not_found unless lease

          now = Agents::Leases::Clock.current
          unless lease.active_at?(now)
            retire(lease, released_at: now)
            next not_found
          end
          next conflict(lease) unless owned?(lease)
          next phase_conflict(lease) if phase_mismatch?(lease)
          next profile_drift(lease) if profile_drifted?(lease)
          if lease.authoritative_ttl_seconds
            next authoritative_ttl_mismatch(lease) if lease.authoritative_ttl_seconds != @params[:ttl_seconds]

            # Il claim queue ha già fissato la deadline della reservation. Un renew compatibile è
            # idempotente: spostare expires_at riaprirebbe max_parallel oltre quella deadline.
            next Result.ok(lease)
          end

          lease.update!(expires_at: now + renew_ttl_seconds(lease).seconds)
          Result.ok(lease)
        end
      rescue ActiveRecord::RecordInvalid => e
        record_invalid(e)
      rescue ActiveRecord::ValueTooLong, RangeError
        invalid(:lease)
      end

      private

      def owned?(lease) = lease.held_by?(@holder) && lease.run_id == @params[:run_id]

      # Host-first: il renew estende alla scadenza della fase pinnata (tetto server-side), non al TTL del
      # client — che per un lease host-first è solo un'assertion. I lease legacy usano il TTL del client.
      def renew_ttl_seconds(lease)
        return @params[:ttl_seconds] if lease.execution_phase.blank?

        Agents::PhaseProfile.for(lease.execution_phase)&.ttl || @params[:ttl_seconds]
      end
    end
  end
end
