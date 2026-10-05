# frozen_string_literal: true

module Agents
  module Attempts
    # Consegna idempotente e fail-closed dell'output strutturato. Gli effetti tipizzati vengono creati
    # soltanto dopo la revisione incrociata e dopo aver rivalidato l'intero scope sotto lock.
    #
    # CYRA-741 — qui restano il lock, il replay, la registrazione del tentativo e il rinvio alla fase.
    # Le altre due metà hanno un posto loro: il contratto della consegna (Attempts::DeliveryContract)
    # dice SE un rapporto è accettabile, e l'effetto della fase (Attempts::Effects::<Fase>, risolto da
    # Agents::PhaseProfile#effect) dice cosa succede quando lo è. Prima erano tutte e tre in questo
    # file, e aggiungere una fase voleva dire aprirlo per intero.
    class Deliver < ApplicationService
      # Tetti delle colonne cost_usd (decimal 14,6) e model (CYRA-872).
      COST_CEILING = 100_000_000
      MODEL_MAX_LENGTH = 100

      def initialize(organization:, host:, attempt:, payload:)
        @organization = organization
        @host = host
        @attempt = attempt
        @payload = payload.to_h.deep_stringify_keys
      end

      def call
        digest = Digest::SHA256.hexdigest(JSON.generate(canonical(@payload)))
        outcome = nil
        ApplicationRecord.transaction do
          lock_scope!
          outcome = replay_result(digest) and next

          validation = contract.call
          if validation
            @attempt.update!(
              result: @payload.fetch("result", {}), review: @payload.fetch("review", {}),
              reviewer_runtime: @payload["reviewer_runtime"], review_status: :unavailable,
              status: :review_failed, review_cycles: @attempt.review_cycles + 1,
              delivery_digest: digest, finished_at: Time.current, **declared_usage
            )
            settle_rejected_phase!
            outcome = validation
            next
          end

          apply_typed_effect!
          @attempt.update!(
            result: @payload.fetch("result"), review: contract.reviewed_review,
            reviewer_runtime: @payload.fetch("reviewer_runtime"), review_status: :accepted,
            status: :approved, review_cycles: @attempt.review_cycles + 1,
            # CYAU-178: l'impronta del codice che l'host aveva in mano resta scritta sul tentativo. È
            # il termine di paragone con cui, più avanti, si distingue una proposta che porta davvero
            # questo lavoro da una che porta quello di un altro ticket o una versione senza l'ultimo invio.
            observed_head_sha: @payload.dig("observed", "head_sha").presence,
            delivery_digest: digest, finished_at: Time.current, **declared_usage
          )
          outcome = Result.ok(@attempt)
        end
        # Cosa parte DOPO il commit lo dice la fase, non questo file: sono job che leggono ciò che
        # l'effetto ha appena scritto, e dentro la transazione girerebbero su righe non ancora visibili
        # o terrebbero righe bloccate per la durata di una chiamata di rete.
        #
        # L'effetto si costruisce anche quando la consegna era un REPLAY e l'effetto non è stato
        # applicato: i due controlli del rilascio (la prova di staging, la sonda di produzione)
        # dipendono dalla sola fase e ripartivano anche allora. Chi dipende da un record creato adesso
        # (la proposta registrata, il piano, il chiarimento) non parte, perché quel record non c'è.
        effect&.after_commit if outcome.ok?
        outcome
      rescue ActiveRecord::RecordNotFound
        stale
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-ATTEMPT-001", details: e.record.errors.to_hash))
      end

      private

      def lock_scope!
        @host.lock!
        @attempt.lock!
        # L'identità del tentativo vive sulle sue colonne immutabili (host, service account, fase): agente,
        # target, comando e istruzione sono spariti coi typed agent (MT-9), e con loro i lock relativi.
        project = @attempt.workflow.ticket.project
        project.lock!
        @attempt.workflow.ticket.lock!
        @attempt.workflow.lock!
        Github::Repository.lock.find_by(project_id: project.id)&.lock!
        @lease = Agents::Lease.lock.find_by!(ticket: @attempt.workflow.ticket)

        now = Agents::Leases::Clock.current
        raise ActiveRecord::RecordNotFound unless @host == @attempt.host && @host.organization_id == @organization.id
        raise ActiveRecord::RecordNotFound unless @lease.host_id == @host.id && @lease.run_id == @attempt.external_run_id
        raise ActiveRecord::RecordNotFound unless lease_matches_attempt?(@lease) && @lease.active_at?(now)
        raise ActiveRecord::RecordNotFound if Agents::Hosts::Eligibility.call(
          host: @host, project:, phase: @attempt.phase
        ).err?
      end

      # Host-first (CYAU-96): il lease pinna la fase eseguibile e l'impronta del profilo (PhaseProfile#digest),
      # e la consegna rivalida su quelli. Il ramo legacy che confrontava lo slug dell'agente è caduto con i typed
      # agent (MT-9): un lease senza fase non è più un caso ammesso, è un lease che non corrisponde.
      def lease_matches_attempt?(lease)
        return false if lease.execution_phase.blank?

        lease.execution_phase == @attempt.phase && profile_pin_valid?(lease)
      end

      # Un tentativo già approvato è un replay idempotente (replay_result deciderà l'esito sul delivery_digest):
      # non ri-rivalidiamo il profilo, così un cambio di PhaseProfile dopo il commit non trasforma una consegna
      # già registrata in un errore stale.
      def profile_pin_valid?(lease)
        @attempt.status_approved? || lease.profile_digest == Agents::PhaseProfile.for(@attempt.phase)&.digest
      end

      def replay_result(digest)
        return unless @attempt.delivery_digest.present?
        return Result.ok(@attempt) if @attempt.delivery_digest == digest && @attempt.status_approved?

        Result.err(AppError.new("Consegna già registrata con un payload diverso",
                                code: "R409-ATTEMPT-002", status: :conflict))
      end

      # La barriera server: nil se il rapporto passa, il Result.err con cui respingerlo altrimenti. È la
      # stessa istanza che poi dice quale profondità di rilettura va scritta sulla review accettata.
      def contract
        @contract ||= DeliveryContract.new(attempt: @attempt, payload: @payload)
      end

      # Che ne è della fase dopo una bocciatura: sotto il tetto torna in coda, al tetto si ferma
      # (CYRA-218). Il conteggio e il blocco vivono in Agents::Workflows::BlockExhaustedPhase — stessa
      # soglia per i tre modi in cui un tentativo si chiude, invece di tre copie destinate a divergere.
      # Qui gira dentro la transazione della consegna, col workflow già sotto lock da lock_scope!: due
      # consegne concorrenti sulla stessa fase non possono contare la stessa metà di storia.
      #
      # Il ramo "sotto il tetto" mancava del tutto, e senza di esso il budget di due cicli non esisteva
      # davvero: il claim ha scritto <fase>_started_at, READY_EXECUTION_PHASE_SQL smette di proporre la
      # fase, e il ticket usciva dalla coda alla PRIMA bocciatura — in silenzio, senza blocco, senza
      # nulla da vedere nell'interfaccia. L'unico modo di farlo ripartire era uno sblocco a mano.
      # Riprovare da soli è esattamente il motivo per cui il tetto è due e non uno.
      def settle_rejected_phase!
        return if Agents::Workflows::BlockExhaustedPhase.call(attempt: @attempt)

        @attempt.workflow.reopen_execution_phase!(@attempt.phase)
      end

      # Il rinvio alla fase. Una fase che nessuno ha dichiarato non ha un effetto e non se ne inventa
      # uno: è lo stesso fail-closed di tutto il resto della consegna.
      def apply_typed_effect!
        raise ActiveRecord::RecordNotFound if effect.nil?

        effect.call
      end

      # UNA istanza per consegna: la stessa che applica l'effetto dentro la transazione risponde poi
      # su cosa far partire dopo il commit, e porta con sé i record che ha creato.
      def effect
        return @effect if defined?(@effect)

        @effect = Agents::PhaseProfile.for(@attempt.phase)&.effect
                                      &.new(attempt: @attempt, host: @host, payload: @payload)
      end

      # Costo e modello dichiarati dall'host: una misura, mai un motivo per rifiutare la consegna.
      # Un valore non valido diventa NULL, cioè «non noto» (CYRA-872).
      def declared_usage
        model = @payload["model"]
        { cost_usd: declared_cost, model: model.is_a?(String) ? model.strip.first(MODEL_MAX_LENGTH).presence : nil }
      end

      def declared_cost
        cost = BigDecimal(@payload["cost_usd"].to_s, exception: false)
        cost if cost&.finite? && cost >= 0 && cost < COST_CEILING
      end

      def canonical(value)
        case value
        when Hash then value.sort.to_h.transform_values { |item| canonical(item) }
        when Array then value.map { |item| canonical(item) }
        else value
        end
      end

      def stale
        Result.err(AppError.new("Tentativo, lease o scope non più validi",
                                code: "R409-ATTEMPT-001", status: :conflict))
      end
    end
  end
end
