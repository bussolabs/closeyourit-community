# frozen_string_literal: true

module Agents
  module TicketQueues
    # Registra un backoff deciso esclusivamente dal server per la selezione firmata. Segue il suffisso
    # host → agent → project → ticket dell'ordine globale del dispatch; il lock sul ticket serializza
    # defer concorrenti e claim, mentre selection_digest rende stabile il replay.
    class Defer < ApplicationService
      Outcome = Data.define(:deferral, :replayed)

      def initialize(organization:, host:, selection_token:, params:)
        @organization = organization
        @host = host
        @selection_token = selection_token
        @params = params.to_h.symbolize_keys
        @snapshot = CandidateSnapshot.new(organization:, host:)
      end

      def call
        selection = Selection.verify(@selection_token)
        return invalid_selection unless Selection.valid_payload?(selection)
        return selection_not_found unless selection[:organization_id] == @organization.id
        return selection_not_found unless selection[:host_id] == @host.id
        @selection = selection
        validation = request_error
        return validation if validation

        digest = Digest::SHA256.hexdigest(@selection_token)
        # Replay per-host (CYAU-92/80): il token è host-bound, ma il replay del digest resta ristretto all'host
        # richiedente come difesa in profondità (indice unico replay esteso con host_id).
        replay = @organization.agent_ticket_queue_deferrals.find_by(selection_digest: digest, host_id: @host.id)
        return replayed(replay) if replay

        context = @snapshot.load(selection)

        result = nil
        Agents::TicketQueueDeferral.transaction do
          context = @snapshot.lock(selection)
          unless context
            result = selection_not_found
            raise ActiveRecord::Rollback
          end
          unless @snapshot.eligible?(context, selection)
            result = stale_selection
            raise ActiveRecord::Rollback
          end
          after_candidate_locked(context)

          now = Agents::Leases::Clock.current
          phase = execution_phase(context)
          existing = Agents::TicketQueueDeferral.active_for(
            host: @host, ticket: context.ticket, execution_phase: phase, at: now
          ).order(:created_at).first
          if existing
            result = replayed(existing)
            next
          end
          if Agents::Lease.where(ticket_id: context.ticket.id).where("expires_at > ?", now).exists?
            result = active_lease
            raise ActiveRecord::Rollback
          end

          # Host-first (CYAU-84): l'API è appiattita (nessun agent_id nell'URL). Il deferral è keyed su
          # host+ticket+execution_phase (CYAU-92); l'agent legacy è ritirato → nil.
          deferral = Agents::TicketQueueDeferral.create!(
            created_at: now,
            updated_at: now,
            organization: @organization,
            ticket: context.ticket,
            host: @host,
            execution_phase: phase,
            reason: @params[:reason],
            retry_at: now + Agents::TicketQueueDeferral::BACKOFFS.fetch(@params[:reason]),
            selection_digest: digest,
            candidate_version: selection[:candidate_version],
            repository_fingerprint: selection[:repository_fingerprint]
          )
          result = Result.ok(Outcome.new(deferral:, replayed: false))
        end
        result
      rescue ActiveRecord::RecordNotFound
        stale_selection
      end

      private

      # Seam di test per provare con PostgreSQL reale la serializzazione defer↔claim.
      def after_candidate_locked(_context) = nil

      # Host-first (CYAU-80/82): la fase è quella firmata nel token (chiave del deferral host+ticket+execution_phase),
      # gemella di Claim#execution_phase.
      def execution_phase(_context)
        @selection.fetch(:execution_phase)
      end

      def replayed(deferral) = Result.ok(Outcome.new(deferral:, replayed: true))

      def request_error
        host_id = @params[:host_id]
        return forbidden_host unless host_id.is_a?(String) && host_id == @host.id &&
                                     @host.organization_id == @organization.id
        return invalid_reason unless Agents::TicketQueueDeferral::REASONS.include?(@params[:reason])

        nil
      end

      def forbidden_host
        Result.err(AppError.new(
                     "L'host autenticato non coincide con host_id", code: "R403-QUEUE-001", status: :forbidden
                   ))
      end

      def invalid_reason
        Result.err(AppError.new("Ragione di defer non valida", code: "R422-QUEUE-003"))
      end

      def invalid_selection
        Result.err(AppError.new("Selezione della coda mancante, non valida o scaduta", code: "R422-QUEUE-001"))
      end

      def selection_not_found
        Result.err(AppError.new("Selezione della coda non trovata", code: "R404-QUEUE-001", status: :not_found))
      end

      def stale_selection
        Result.err(AppError.new(
                     "La selezione della coda non è più eleggibile", code: "R409-QUEUE-001", status: :conflict
                   ))
      end

      def active_lease
        Result.err(AppError.new(
                     "Il ticket è già stato reclamato", code: "R409-QUEUE-004", status: :conflict
                   ))
      end
    end
  end
end
