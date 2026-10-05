# frozen_string_literal: true

module Agents
  module Leases
    class Acquire < Operation
      Outcome = Data.define(:lease, :fresh_acquisition)
      TicketDisappeared = Class.new(StandardError)
      LeaseChangedTooOften = Class.new(StandardError)
      LEASE_STATE_RETRIES = 2

      def initialize(organization:, holder:, ticket_reference:, params:, authoritative_expires_at: nil)
        super(organization:, holder:, ticket_reference:, params:)
        @authoritative_expires_at = authoritative_expires_at
      end

      def call
        validation = prepare(require_ttl: true, require_identity: true, require_scope: true)
        return validation if validation

        result = Agents::Lease.transaction do
          next forbidden_host unless lock_active_holder
          next ticket_not_found unless lock_ticket
          next released_acquisition if tombstoned?

          lease, created = find_and_lock_lease
          now = Agents::Leases::Clock.current
          if authoritative_expired_at?(now)
            lease.destroy! if created
            next authoritative_expired
          end

          if created
            Result.ok(Outcome.new(lease:, fresh_acquisition: true))
          elsif lease.active_at?(now)
            if !owned?(lease)
              conflict(lease)
            elsif phase_mismatch?(lease)
              phase_conflict(lease)
            elsif profile_drifted?(lease)
              profile_drift(lease)
            else
              refresh_owned_lease!(lease)
              Result.ok(Outcome.new(lease:, fresh_acquisition: false))
            end
          elsif owned?(lease)
            retire(lease, released_at: now)
            released_acquisition
          else
            record_tombstone(lease, released_at: now)
            lease.update!(
              **@holder.ownership_attributes,
              run_id: @params[:run_id],
              agent: @params[:agent],
              execution_phase:,
              profile_digest:,
              expires_at: lease_expiry(now),
              authoritative_ttl_seconds: authoritative_ttl_seconds
            )
            Result.ok(Outcome.new(lease:, fresh_acquisition: true))
          end
        end
        result
      rescue ActiveRecord::RecordInvalid => e
        record_invalid(e)
      rescue ActiveRecord::ValueTooLong, RangeError
        invalid(:lease)
      rescue TicketDisappeared
        ticket_not_found
      rescue LeaseChangedTooOften
        lease_unavailable
      end

      private

      # Il ticket lock condiviso elimina le race tra writer aggiornati. Il retry complessivo copre i
      # writer legacy sia durante create_or_find_by! sia nella finestra ritorno → lease.lock!, senza
      # moltiplicare i tentativi con cicli annidati. Tombstone e mutazione avvengono soltanto dopo
      # il lock riuscito, fuori da questo ciclo, quindi non vengono ripetute dai retry.
      def find_and_lock_lease
        retries = 0
        begin
          lease = find_or_create_lease
          created = lease.previously_new_record?
          lease.lock!
          [ lease, created ]
        rescue ActiveRecord::RecordNotFound
          raise TicketDisappeared unless Ticketing::Ticket.exists?(@ticket.id)

          retries += 1
          retry if retries <= LEASE_STATE_RETRIES

          raise LeaseChangedTooOften
        end
      end

      def find_or_create_lease = create_or_find_lease

      def create_or_find_lease
        Agents::Lease.create_or_find_by!(ticket: @ticket) do |lease|
          lease.assign_attributes(
            ownership_attributes(expires_at: lease_expiry)
          )
        end
      end

      def lease_expiry(now = Agents::Leases::Clock.current)
        @authoritative_expires_at || now + effective_ttl_seconds.seconds
      end

      # Host-first diretto (senza finestra autoritativa dal claim): il TTL è quello del PhaseProfile della
      # fase, non il valore del client — che resta solo un'assertion. Il path legacy (senza fase) usa il client.
      def effective_ttl_seconds = phase_ttl_seconds || @params[:ttl_seconds]

      def authoritative_expired_at?(now)
        @authoritative_expires_at && @authoritative_expires_at <= now
      end

      # Solo il claim autoritativo fissa una deadline immutabile (rispetta il max_parallel della reservation).
      # Un acquire host-first diretto resta un lease normale rinnovabile: la scadenza è cappata alla fase via
      # effective_ttl_seconds, ma non è marcata autoritativa (altrimenti Renew non potrebbe più estenderla).
      def authoritative_ttl_seconds
        @params[:ttl_seconds] if @authoritative_expires_at
      end

      # Lease già posseduto (stesso host/run), attivo. Tre casi distinti; un profilo già pinnato resta immutato
      # (un drift è già respinto a monte da profile_drifted?):
      #   - claim autoritativo → adozione/idempotenza con ri-attribuzione agent e finestra della reservation;
      #   - acquire diretto che converte un lease legacy → pin + cap della scadenza al TTL della fase;
      #   - retry idempotente puro → NESSUNA mutazione (slug agent e scadenza legacy vanno preservati, o si
      #     romperebbe la delivery legacy in corso).
      def refresh_owned_lease!(lease)
        if @authoritative_expires_at
          adopt_under_authoritative_window!(lease)
        elsif converting_to_host_first?(lease)
          convert_to_host_first!(lease)
        end
      end

      # Claim autoritativo: ri-attribuisce lo slug agent, pinna fase/profilo se assenti (legacy→host-first) e
      # sincronizza la deadline immutabile della reservation.
      def adopt_under_authoritative_window!(lease)
        attributes = { agent: @params[:agent],
                       expires_at: @authoritative_expires_at, authoritative_ttl_seconds: }
        attributes[:execution_phase] = execution_phase if lease.execution_phase.blank?
        attributes[:profile_digest] = profile_digest if lease.profile_digest.blank?
        lease.update!(attributes)
      end

      def converting_to_host_first?(lease) = lease.execution_phase.blank? && execution_phase.present?

      # Conversione diretta legacy→host-first (senza finestra autoritativa): pinna fase e profilo, adotta lo slug
      # agent host-first e CAPPA la scadenza al TTL della fase — un expires_at legacy (fino a 30 giorni) non deve
      # sopravvivere al tetto server-side della fase.
      def convert_to_host_first!(lease)
        attributes = { agent: @params[:agent], execution_phase:, profile_digest: }
        # La conversione non rinnova: cappa solo un eventuale eccesso. La nuova scadenza è il MINORE tra
        # quella esistente e il TTL della fase (un lease più corto resta corto). Una deadline autoritativa
        # da un claim resta invece immutabile (la finestra della reservation non va toccata).
        attributes[:expires_at] = [ lease.expires_at, lease_expiry ].min if lease.authoritative_ttl_seconds.nil?
        lease.update!(attributes)
      end

      def ownership_attributes(expires_at:)
        {
          organization: @organization,
          run_id: @params[:run_id],
          agent: @params[:agent],
          execution_phase:,
          profile_digest:,
          expires_at:,
          authoritative_ttl_seconds:
        }.merge(@holder.ownership_attributes)
      end

      # execution_phase è l'assertion del client; il PhaseProfile della fase è l'AUTORITÀ server-side per
      # digest e TTL — il client non controlla nessuno dei due. Fase ignota → nil → il modello la rifiuta.
      def execution_phase = @params[:execution_phase].presence

      def phase_profile
        return @phase_profile if defined?(@phase_profile)

        @phase_profile = execution_phase && Agents::PhaseProfile.for(execution_phase)
      end

      def profile_digest = phase_profile&.digest

      def phase_ttl_seconds = phase_profile&.ttl

      def owned?(lease) = lease.held_by?(@holder) && lease.run_id == @params[:run_id]
    end
  end
end
