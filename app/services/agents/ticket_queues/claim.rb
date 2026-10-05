# frozen_string_literal: true

module Agents
  module TicketQueues
    # Converte una selezione firmata della coda in un lease. Tutte le condizioni mutabili vengono
    # rilette sotto lock nella stessa transazione dell'acquisizione, così il preflight non apre una
    # finestra TOCTOU per host, capability, target, repository, ticket o stato terminale.
    class Claim < ApplicationService
      Outcome = Data.define(:lease, :fresh_acquisition, :attempt)

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

        initial_context = @snapshot.load(selection)
        return stale_selection unless @snapshot.eligible?(initial_context, selection) || idempotent_replay?(initial_context)
        return ttl_mismatch(initial_context) unless authoritative_ttl?(initial_context)

        claim_result = nil
        # `requires_new` (CYRA-588): chiamato dentro la transazione della presa in carico atomica
        # (ClaimNext), un `transaction` normale si limiterebbe a unirsi a quella aperta, e Rails
        # INGHIOTTIREBBE in silenzio gli `ActiveRecord::Rollback` qui sotto — reservation, usage e lease
        # di un candidato diventato stale resterebbero scritti. Col savepoint il rollback annulla di
        # nuovo davvero ciò che è nato qui dentro. Senza transazione esterna (percorso in due passi) è
        # indistinguibile da prima: apre la transazione e basta.
        Agents::Lease.transaction(requires_new: true) do
          reservation_result = reserve_limit(initial_context, selection)
          if reservation_result.err?
            claim_result = authoritative_ttl?(initial_context) ? stale_selection : ttl_mismatch(initial_context)
            raise ActiveRecord::Rollback
          end

          reservation = reservation_result.value.reservation
          after_limit_reserved(reservation)

          context = @snapshot.lock(selection)
          unless context
            claim_result = selection_not_found
            raise ActiveRecord::Rollback
          end
          unless @snapshot.eligible?(context, selection) || idempotent_replay?(context)
            claim_result = stale_selection
            raise ActiveRecord::Rollback
          end
          eligibility = Agents::Hosts::Eligibility.call(host: @host, project: context.project, phase: execution_phase(context))
          if eligibility.err?
            claim_result = eligibility
            raise ActiveRecord::Rollback
          end
          # CYRA-595 — fra il momento in cui la coda ha proposto il ticket e questo istante può essere
          # partito un altro rilascio sullo stesso repository: la coda filtra a monte, ma non è un
          # lucchetto. Qui il progetto è già bloccato in riga da entrambi i pretendenti, quindi il
          # ricontrollo è l'unico punto in cui la risposta non può più cambiare sotto i piedi.
          #
          # Ha un codice suo, non quello generico della selezione scaduta: «un altro sta rilasciando»
          # è un fatto temporaneo con un nome e una durata, e chi legge deve poterlo distinguere da
          # «questa selezione non vale più».
          if execution_phase(context) == "closer_production" && !idempotent_replay?(context)
            in_corso = Agents::Workflows::ProductionLock.holder(project: context.project,
                                                                except: context.workflow)
            if in_corso
              claim_result = production_busy(in_corso)
              raise ActiveRecord::Rollback
            end
            # CYRA-871 — fra la proposta e la presa può essere comparso un errore nuovo in staging.
            hold = Agents::Workflows::ProductionHold.reason(context.workflow, now: Agents::Leases::Clock.current)
            if hold
              claim_result = production_held(hold)
              raise ActiveRecord::Rollback
            end
          end
          active_deferral = Agents::TicketQueueDeferral.active_for(
            host: @host, ticket: context.ticket, execution_phase: execution_phase(context),
            at: Agents::Leases::Clock.current
          ).order(:created_at).first
          if active_deferral
            claim_result = deferred(active_deferral)
            raise ActiveRecord::Rollback
          end
          unless reservation.granted?
            claim_result = limit_denied(reservation)
            next
          end

          lease_result = Agents::Leases::Acquire.call(
            organization: @organization,
            holder: Agents::Leases::Holder.host(@host),
            ticket_reference: context.ticket.code,
            params: lease_params(context, reservation),
            authoritative_expires_at: reservation.expires_at
          )
          if lease_result.err?
            claim_result = lease_result
            raise ActiveRecord::Rollback
          end

          attempt = ensure_attempt!(context, selection)
          # L'attempt trovato è TERMINALE: la stessa lavorazione (host + fase + ticket + run) è già stata
          # chiusa — tipicamente dichiarata ferma dal controllo periodico (CYRA-201) dopo aver perso la
          # finestra. Non si riapre: `Attempt#ensure_mutable` solleva su un record terminale, e a valle
          # `Deliver` non intercetta ReadOnlyRecord → sarebbe un 500 al posto di un conflitto. La selezione
          # è semplicemente stale, e l'host ne riceve una nuova al giro dopo.
          unless attempt
            claim_result = stale_selection
            raise ActiveRecord::Rollback
          end

          acquisition = lease_result.value
          # CYRA-621 — il numero di versione si assegna PRIMA che la fase parta, e lo assegna il
          # server. La macchina lo riceve con l'incarico e lo usa: non lo sceglie più leggendo
          # l'ultimo tag e decidendo da sé quale cifra cambiare.
          #
          # Se non si riesce ad assegnarlo, la fase non parte: pubblicare senza un numero deciso qui
          # rimetterebbe in piedi esattamente il difetto — due lavorazioni che scelgono lo stesso
          # nome, e una versione di prova che non torna con la definitiva.
          assignment = Agents::Releases::Assign.call(workflow: context.workflow,
                                                       execution_phase: execution_phase(context))
          if assignment.err?
            claim_result = assignment
            raise ActiveRecord::Rollback
          end
          # Snapshot immutabile della Guidance consegnata a QUESTA presa in carico (CYRA-76): dentro la
          # transazione del claim (o claim + snapshot o niente) e idempotente per ticket, così claim
          # concorrenti/replay non lo duplicano. Cattura la guidance CORRENTE, non quella alla creazione.
          capture_work_context(context)
          claim_result = Result.ok(
            Outcome.new(lease: acquisition.lease, fresh_acquisition: acquisition.fresh_acquisition, attempt:)
          )
        end
        claim_result
      rescue ActiveRecord::RecordNotFound
        stale_selection
      end

      private

      # Punto di sincronizzazione intenzionale per dimostrare nei test PostgreSQL che un candidato
      # diventato stale dopo una decisione di limite fa rollback reservation, usage e lease.
      def after_limit_reserved(_reservation) = nil

      # Fotografa la Guidance corrente del progetto in uno snapshot immutabile per ticket (CYRA-76).
      # L'attore è il service account dell'host che prende in carico (optional per host storici senza
      # identità). Idempotente: un secondo claim sullo stesso ticket trova lo snapshot e non lo duplica.
      def capture_work_context(context)
        Ticketing::CaptureWorkContext.call(ticket: context.ticket, actor: @host.service_account)
      end

      def reserve_limit(context, selection)
        Agents::Limits::Reserve.call(
          organization: @organization,
          host: @host,
          project: context.project,
          phase: execution_phase(context),
          idempotency_key: limit_idempotency_key(context),
          estimated_cost: selection[:estimated_cost]
        )
      end

      # Host-first (CYAU-82): la fase autoritativa è quella firmata nel token, validata da valid_payload? e
      # ri-confrontata sotto lock con Workflow#ready_execution_phase (CandidateSnapshot#eligible?). Propaga a
      # Reserve/Eligibility/deferral/lease_params/phase_ttl. Deliver la legge da attempt.phase.
      def execution_phase(_context)
        @selection.fetch(:execution_phase)
      end

      # La fase è aggiunta all'identità della richiesta da Limits::Reserve (idempotency phase-scoped);
      # qui la key resta host/ticket/run.
      def limit_idempotency_key(context)
        digest = Digest::SHA256.hexdigest(
          [ @organization.id, @host.id, context.ticket.id, @params[:run_id] ].join("\0")
        )
        "queue-claim:#{digest}"
      end

      # Host-first (CYAU-84/96): il lease pinna la fase eseguibile e Acquire deriva il profile_digest
      # autoritativo dal PhaseProfile. Appiattita l'API (nessun agent_id), lo slug agent dual-stack è ritirato:
      # il lease nasce host-first puro (execution_phase + profile_digest, che Deliver rivalida), agent = nil.
      def lease_params(context, reservation)
        {
          ticket: context.ticket.code,
          host_id: @params[:host_id],
          run_id: @params[:run_id],
          execution_phase: execution_phase(context),
          ttl_seconds: reservation.requested_ttl_seconds
        }
      end

      def authoritative_ttl?(context) = @params[:ttl_seconds] == phase_ttl(context)

      def phase_ttl(context) = Agents::PhaseProfile.for(execution_phase(context))&.ttl

      # Host-first (CYAU-82): l'Attempt è host-first (service_account + profilo immutabile dal PhaseProfile),
      # senza agent/command/instruction (XOR execution_identity_present del modello). Fallisce chiuso su fase
      # ignota via PhaseProfile.fetch (KeyError).
      #
      # Ritorna `nil` quando l'attempt esistente è già in uno stato TERMINALE (CYRA-201): il chiamante lo
      # tratta come selezione stale invece di consegnare un record immutabile a valle.
      def ensure_attempt!(context, selection)
        profile = Agents::PhaseProfile.fetch(execution_phase(context))

        attempt = Agents::Attempt.find_or_create_by!(organization: @organization, idempotency_key: attempt_key(context)) do |record|
          record.assign_attributes(
            # CYRA-921 — the runtime is the machine's work engine; delivery checks the reviewer against it.
            **profile.to_h, runtime: @host.work_engine, phase: profile.phase, workflow: context.workflow, host: @host,
            service_account: @host.service_account, external_run_id: @params[:run_id],
            status: :running, started_at: Agents::Leases::Clock.current
          )
        end
        return nil if attempt.status.in?(Agents::Attempt::TERMINAL_STATUSES)

        mark_workflow_started!(context.workflow, selection) if attempt.previously_new_record?
        attempt
      end

      # Il motivo, con il ticket che tiene la fila e da quando: senza quei due dati chi legge sa che
      # deve aspettare ma non cosa. Il codice del ticket si omette se chi chiede non può vederlo.
      def production_busy(workflow)
        ticket = workflow.ticket
        project_visible = Agents::Hosts::ProjectScope.new(host: @host).allows?(ticket.project)
        Result.err(AppError.new(
          "Un rilascio in produzione è già in corso su questo repository",
          code: "R409-QUEUE-006", status: :conflict,
          details: { code: (ticket.code if project_visible), since: workflow.closer_production_started_at }.compact
        ))
      end

      def production_held(hold)
        Result.err(AppError.new(
          "Il rilascio in produzione aspetta la prova dello staging",
          code: "R409-QUEUE-007", status: :conflict, details: hold
        ))
      end

      def idempotent_replay?(context)
        Agents::Attempt.where(
          organization: @organization, workflow: context.workflow, host: @host,
          phase: execution_phase(context), idempotency_key: attempt_key(context),
          status: %i[running awaiting_review]
        ).exists?
      end

      # Idempotency host-first: host + fase + ticket + run (niente più agent/instruction).
      def attempt_key(context)
        digest = Digest::SHA256.hexdigest(
          [ @organization.id, @host.id, execution_phase(context), context.ticket.id, @params[:run_id] ].join("\0")
        )
        "claim:#{digest}"
      end

      # Host-first (CYAU-82): attribuisce la fase avviata all'host + service account (colonne *_by_host_id /
      # *_by_service_account_id di CYAU-83), senza i puntatori legacy *_by_agent. Rispetta l'asimmetria colonna
      # `planned` ↔ fase `planner` (il planner non ha un `planned_started_at`).
      def mark_workflow_started!(workflow, selection)
        host = @host
        service_account = @host.service_account
        attributes = {
          ticket_snapshot_digest: selection[:candidate_version],
          ticket_snapshot_version: workflow.ticket_snapshot_version + (workflow.ticket_snapshot_digest.present? ? 1 : 0)
        }
        case selection[:execution_phase]
        when "triage"
          attributes.merge!(triage_started_at: Time.current, triage_by_host: host, triage_by_service_account: service_account)
        when "planner"
          attributes.merge!(planned_by_host: host, planned_by_service_account: service_account)
        when "autopilot"
          attributes.merge!(autopilot_started_at: Time.current, autopilot_by_host: host, autopilot_by_service_account: service_account)
        when "closer_staging"
          attributes.merge!(closer_staging_started_at: Time.current, closer_staging_by_host: host, closer_staging_by_service_account: service_account)
        when "closer_production"
          attributes.merge!(closer_production_started_at: Time.current, closer_production_by_host: host, closer_production_by_service_account: service_account)
        end
        workflow.update!(attributes)
      end

      def request_error
        host_id = @params[:host_id]
        return invalid_lease(:host_id) unless host_id.is_a?(String) && host_id.present?
        return forbidden_host unless @host.organization_id == @organization.id && host_id == @host.id
        return invalid_lease(:run_id) unless valid_identifier?(@params[:run_id])

        ttl = @params[:ttl_seconds]
        return invalid_lease(:ttl_seconds) unless ttl.is_a?(Integer) && ttl.between?(1, 30.days.to_i)

        nil
      end

      def valid_identifier?(value)
        value.is_a?(String) && value.present? && value.length <= 255
      end

      def invalid_lease(field)
        Result.err(
          AppError.new(
            "Richiesta lease non valida", code: "R422-LEASE-001",
            details: { field => [ I18n.t("errors.messages.invalid") ] }
          )
        )
      end

      def forbidden_host
        Result.err(
          AppError.new(
            "L'host autenticato non coincide con host_id", code: "R403-LEASE-001", status: :forbidden
          )
        )
      end

      def invalid_selection
        Result.err(
          AppError.new("Selezione della coda mancante, non valida o scaduta", code: "R422-QUEUE-001")
        )
      end

      def selection_not_found
        Result.err(AppError.new("Selezione della coda non trovata", code: "R404-QUEUE-001", status: :not_found))
      end

      def stale_selection
        Result.err(
          AppError.new("La selezione della coda non è più eleggibile", code: "R409-QUEUE-001", status: :conflict)
        )
      end

      def ttl_mismatch(context)
        Result.err(
          AppError.new(
            "Il TTL richiesto non coincide con il timeout autoritativo della fase",
            code: "R409-QUEUE-005",
            status: :conflict,
            details: {
              requested_ttl_seconds: @params[:ttl_seconds],
              expected_ttl_seconds: phase_ttl(context)
            }
          )
        )
      end

      def limit_denied(reservation)
        unavailable = reservation.denial_reason == "estimated_cost_unavailable"
        Result.err(
          AppError.new(
            unavailable ? "Costo stimato server-side non disponibile" : "Claim negato dai limiti server-side",
            code: unavailable ? "R422-QUEUE-002" : "R409-QUEUE-002",
            status: unavailable ? :unprocessable_content : :conflict,
            details: { reason: reservation.denial_reason }
          )
        )
      end

      def deferred(deferral)
        Result.err(
          AppError.new(
            "Il ticket è deferito per questo agente", code: "R409-QUEUE-003", status: :conflict,
            details: { reason: deferral.reason, retry_at: deferral.retry_at }
          )
        )
      end
    end
  end
end
