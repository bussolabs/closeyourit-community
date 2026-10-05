# frozen_string_literal: true

module Agents
  module TicketQueues
    # Sceglie il candidato E lo prende in carico dentro UNA transazione (CYRA-588). Il percorso in due
    # passi — Next firma la testa della coda, Claim la rilegge sotto lock — è atomico ma non drena in
    # parallelo: due postazioni vedono lo stesso ticket in cima, una lo prende e le altre ricevono
    # `stale_selection`, buttando via il giro. Qui il candidato si sceglie già lockato (FOR UPDATE ...
    # SKIP LOCKED), quindi chiamate concorrenti prendono righe diverse invece di contendersi la testa.
    #
    # Il corpo della presa in carico NON è riscritto: il candidato viaggia nella stessa capability firmata
    # del percorso in due passi e finisce in Agents::TicketQueues::Claim. Il claim non guadagna un secondo
    # ingresso di cui fidarsi — riceve lo stesso e riesegue gli stessi gate (Eligibility sotto lock,
    # Limits::Reserve, deferral, lease host-first con execution_phase + profile_digest).
    #
    # NON è idempotente per run_id, di proposito: qui la richiesta è «dammi lavoro», non «prendi QUESTO
    # ticket», e il run_id resta libero di ripetersi su ticket diversi come nel percorso in due passi
    # (l'identità del claim è host + fase + ticket + run). Un client che ritenta dopo una risposta persa
    # riceve quindi un secondo ticket, e il primo torna in coda alla scadenza del lease.
    class ClaimNext < ApplicationService
      Outcome = Data.define(:ticket, :lease, :fresh_acquisition, :attempt)

      def initialize(organization:, project_key:, host:, params:)
        @organization = organization
        @project_key = project_key
        @host = host
        @params = params.to_h.symbolize_keys
      end

      def call
        # Stesso gate di preflight di Next: certificazione host-side (la revoca è già respinta dall'auth),
        # mentre l'Eligibility completa resta l'autorità sotto lock dentro il Claim.
        return host_ineligible unless @host.supported_platform? && @host.certified?

        project = Candidates.project_for(organization: @organization, host: @host, key: @project_key)
        return project_not_found unless project

        result = nil
        Agents::Lease.transaction do
          lock_dispatch_prefix!(project)
          candidates = Candidates.new(project:, host: @host)
          id = candidates.locked_head_id
          if id.nil?
            result = no_work
            next
          end

          result = claim(candidates.snapshot(id))
        end
        result
      end

      private

      # Ordine globale del dispatch (Agents::Limits::Reserve): policy → host → project → ticket. Il
      # candidato si sceglie DOPO i primi tre lock, non prima: un claim già in corso tiene le policy e
      # aspetta un ticket, e chi arrivasse col ticket in mano aspettando le policy chiuderebbe il ciclo —
      # PostgreSQL ne ucciderebbe uno per deadlock. Le policy prese qui sono un SOVRAINSIEME di quelle che
      # Reserve rileggerà (che filtra anche per runtime, ignoto finché non si sa quale fase è pronta):
      # stesso ordine crescente di id, quindi nessun ciclo.
      #
      # Prendere il prefisso serializza sulla stessa coda le prese in carico concorrenti, che però non si
      # ostacolano: la seconda attende il commit della prima — millisecondi — e poi sceglie il candidato
      # successivo, invece di scoprire a fine giro che la sua selezione era stale.
      def lock_dispatch_prefix!(project)
        Agents::LimitPolicy.where(organization: @organization, project: [ nil, project ]).order(:id).lock.load
        @host.lock!
        project.lock!
      end

      def claim(candidate)
        # La query seleziona solo righe con una fase pronta e il candidato è già lockato, quindi qui la
        # fase c'è. Se le due gemelle (SQL e Ruby) divergessero, la coda dice «niente lavoro» invece di
        # firmare una selezione senza fase.
        phase = candidate.agent_workflow&.ready_execution_phase
        return no_work unless phase

        estimated_cost = Selection.estimated_cost_for(ticket: candidate)
        result = Claim.call(
          organization: @organization,
          host: @host,
          selection_token: Selection.issue(ticket: candidate, host: @host, execution_phase: phase, estimated_cost:),
          params: @params.merge(ttl_seconds: Agents::PhaseProfile.fetch(phase).ttl)
        )
        return result if result.err?

        acquisition = result.value
        Result.ok(
          Outcome.new(
            ticket: candidate, lease: acquisition.lease,
            fresh_acquisition: acquisition.fresh_acquisition, attempt: acquisition.attempt
          )
        )
      end

      # Coda vuota: non è un errore, è l'assenza di lavoro — la stessa risposta del preflight.
      def no_work = Result.ok(nil)

      def host_ineligible
        Result.err(AppError.new("Host non eleggibile", code: "R403-AGENT-006", status: :forbidden))
      end

      def project_not_found
        Result.err(AppError.new("Progetto non trovato", code: "R404-AGENT-002", status: :not_found))
      end
    end
  end
end
