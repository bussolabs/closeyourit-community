# frozen_string_literal: true

module Ops
  # Throughput del MOTORE DEI JOB (Solid Queue), gemello di Ops::WorkerLiveness (CYRA-299). Il
  # battito dei processi Worker (WorkerLiveness) non basta: un worker vivo può comunque non smaltire
  # nulla — è successo con la coda dichiarata come stringa in `queue.yml` (vedi CLAUDE.md), che ha
  # fermato tutti i job in produzione per due giorni senza un solo errore e senza che l'heartbeat se
  # ne accorgesse. Qui il segnale è distinto: c'è lavoro PRONTO (`solid_queue_ready_executions`) e
  # nessun `SolidQueue::Job` è finito da oltre STALL_THRESHOLD (o non è mai finito nulla).
  class QueueThroughput
    # Coerente con la cadenza dei cron ricorrenti (1-15', vedi config/recurring.yml): assorbe qualche
    # ciclo di polling/dispatch perso senza generare un falso allarme durante deploy/restart worker.
    STALL_THRESHOLD = 10.minutes

    class << self
      # Stallo = c'è lavoro pronto da reclamare MA niente lo sta smaltendo. Coda vuota (ready_count
      # zero) non è mai stallo, indipendentemente da quanto sia vecchio last_finished_at: assenza di
      # lavoro non è distinguibile da guasto guardando solo il timestamp.
      def stalled?(now: Time.current, ready_count: self.ready_count, last_finished_at: self.last_finished_at)
        ready_count.positive? && (last_finished_at.nil? || last_finished_at < now - STALL_THRESHOLD)
      end

      def ready_count = SolidQueue::ReadyExecution.count

      def last_finished_at = SolidQueue::Job.where.not(finished_at: nil).maximum(:finished_at)
    end
  end
end
