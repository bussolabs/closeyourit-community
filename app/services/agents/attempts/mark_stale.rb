# frozen_string_literal: true

module Agents
  module Attempts
    # Chiude le lavorazioni ORFANE (CYRA-201): prenotazione scaduta e nessun risultato consegnato.
    #
    # `Agents::Attempt` ha otto stati, ma solo tre punti in app/ ne assegnavano uno diverso da `running`
    # (Deliver → review_failed/approved, Workflows::Cancel → cancelled, azione umana con motivazione).
    # `stale` era LETTO dalle viste e mai scritto da nessuno: una lavorazione che perde la finestra restava
    # quindi "in corso" per sempre, occupava gli attempt attivi e — peggio — poteva farsi scambiare da
    # `TicketQueues::Claim#idempotent_replay?` per un tentativo già in corso, bloccando i claim successivi
    # sullo stesso ticket. L'unico rimedio era manuale.
    #
    # Non è una cancellazione: `stale` è terminale e l'attempt resta come audit (result, review, host,
    # fase). Chiude solo la finestra, con `finished_at` valorizzato come fanno gli altri esiti terminali.
    #
    # CYRA-212 — chiudere l'attempt NON basta a far tornare il ticket disponibile: il claim ha scritto
    # <fase>_started_at sul workflow e READY_EXECUTION_PHASE_SQL smette di proporre quella fase finché lo
    # start resta valorizzato, quindi il ticket sparisce dalla coda per sempre. Nella stessa transazione si
    # riapre perciò la fase interrotta (Workflow#reopen_execution_phase!), così il lavoro riprende invece di
    # sparire. Il planner non ha uno start dedicato: torna in coda da solo alla scadenza del lease.
    #
    # CYRA-1113 — la chiusura dice PERCHÉ. In `failure_reason` (lo stesso campo di ReportFailure) va un
    # codice stabile, mai prosa, seguito dall'ora del fatto e dai minuti passati dall'inizio del tentativo:
    #   "lease_released at=2026-11-12T10:03:00Z minutes=3"
    # La scheda lo traduce (Member::AutomationConsiderationsHelper), la macchina lo legge dal serializer.
    # Chi passa un blocco riceve ogni tentativo chiuso a transazione conclusa: è il registro del giro.
    class MarkStale < ApplicationService
      def initialize(now: Time.current, grace: Agents::Constants::ATTEMPT_STALE_GRACE, &on_mark)
        @now = now
        @grace = grace
        @on_mark = on_mark
      end

      def call
        marked = 0
        # Gli id si raccolgono FUORI dalla transazione: la lista è uno snapshot, e ogni riga viene poi
        # rivalidata sotto lock. Un attempt che ha consegnato nel frattempo va saltato, non forzato.
        Agents::Attempt.orphaned_at(@now, grace: @grace).pluck(:id).each do |id|
          attempt = mark_one(id)
          next unless attempt

          marked += 1
          @on_mark&.call(attempt)
        end
        Result.ok(marked)
      end

      private

      def mark_one(id)
        ApplicationRecord.transaction do
          attempt = Agents::Attempt.lock.find_by(id: id)
          # Rivalutazione sotto lock: la consegna può essere arrivata tra lo snapshot e adesso. In quel caso
          # l'attempt non è più `running` (Deliver lo porta a approved/review_failed) e non va toccato —
          # dichiarare ferma una lavorazione appena conclusa sarebbe peggio del problema di partenza.
          next nil unless attempt&.status_running? && attempt.delivery_digest.blank?

          finished_at = Time.current
          attempt.update!(status: :stale, finished_at:, failure_reason: stale_reason(attempt, finished_at))
          # Recovery della coda (CYRA-212): riapre la fase avviata e mai conclusa così il ticket torna
          # proposto alle macchine invece di restare fuori dalla coda per sempre.
          attempt.workflow.reopen_execution_phase!(attempt.phase)
          # …ma non all'infinito (CYRA-504): una prenotazione che scade sempre sulla stessa fase è una
          # lavorazione che deve chiamare una persona. Il tetto stava sulla sola strada della consegna,
          # che qui non passa. Ogni tentativo va valutato col SUO: MarkStale cicla su più orfani.
          Agents::Workflows::BlockExhaustedPhase.call(attempt: attempt)
          attempt
        end
      end

      # I quattro modi in cui una lavorazione perde la prenotazione, letti sotto lo stesso lock della
      # chiusura. L'ordine conta: la riga lease del ticket dice il presente (un'altra run, o la nostra
      # scaduta); solo quando è sparita si cerca la traccia del rilascio di QUESTA run (ticket + host + run).
      def stale_reason(attempt, finished_at)
        lease = Agents::Lease.find_by(ticket_id: attempt.workflow.ticket_id)
        code, at =
          if lease && lease.run_id != attempt.external_run_id
            [ "lease_taken_by_other_run", lease.created_at ]
          elsif lease
            [ "lease_expired", lease.expires_at ]
          elsif (tombstone = tombstone_for(attempt))
            [ "lease_released", tombstone.released_at ]
          else
            # Nessuna traccia (es. un annullamento a mano che distrugge la riga): si sa solo che non c'era più.
            [ "lease_missing", finished_at ]
          end
        minutes = [ ((at - attempt.started_at) / 60).floor, 0 ].max
        "#{code} at=#{at.utc.iso8601} minutes=#{minutes}"[0, Agents::Constants::FAILURE_REASON_MAX]
      end

      def tombstone_for(attempt)
        Agents::Leases::Tombstone
          .where(ticket_id: attempt.workflow.ticket_id, host_id: attempt.host_id, run_id: attempt.external_run_id)
          .order(released_at: :desc)
          .first
      end
    end
  end
end
