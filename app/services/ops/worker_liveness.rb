# frozen_string_literal: true

module Ops
  # Liveness del MOTORE DEI JOB in background (Solid Queue), interrogata dal processo WEB e perciò
  # indipendente dal processo worker. Ogni processo Solid Queue (supervisor/dispatcher/worker/scheduler)
  # scrive un heartbeat in `solid_queue_processes` (DB queue, condiviso fra i container): se nessuno batte
  # da oltre HEARTBEAT_TIMEOUT il worker è fermo e i controlli ricorrenti — uptime, server, cron, alerting —
  # non girano più, lasciando gli stati all'ultima fotografia (CYRA-209). In produzione il web NON esegue
  # Solid Queue (`SOLID_QUEUE_IN_PUMA=false`): non guardiamo il processo locale ma la tabella globale.
  class WorkerLiveness
    # Allineato al `process_alive_threshold` di default di Solid Queue: oltre questa età senza battito è lo
    # stesso Solid Queue a considerare morto un processo. L'heartbeat batte ~ogni 60s, quindi la soglia
    # assorbe qualche battito perso (deploy/restart del worker) senza far scattare un falso allarme.
    HEARTBEAT_TIMEOUT = 5.minutes

    # Il ruolo che ESEGUE i job. Guardare "un processo qualunque" NON basta: coi soli Supervisor/Dispatcher
    # vivi e i Worker in crash-loop nessun controllo verrebbe eseguito, ma l'endpoint resterebbe verde. Il
    # Worker è anche l'unico ruolo presente in OGNI ambiente in cui i job girano (worker dedicato in prod,
    # dentro Puma in staging), a differenza dello Scheduler che parte solo dove ci sono task ricorrenti
    # (recurring.yml: production and development, CYRA-932). Solid Queue registra `kind` = nome classe demodulizzato → il Worker
    # è esattamente "Worker" (il Supervisor è "Supervisor(<mode>)", quindi non collide).
    EXECUTOR_KIND = "Worker"

    class << self
      # C'è almeno un Worker vivo? False anche a tabella vuota (nessuno registrato = motore fermo).
      def alive?(now: Time.current) = last_heartbeat_at(now:).present?

      # Battito più recente tra i Worker ancora vivi (entro la finestra), o nil se nessun esecutore batte.
      def last_heartbeat_at(now: Time.current)
        SolidQueue::Process.where(kind: EXECUTOR_KIND, last_heartbeat_at: (now - HEARTBEAT_TIMEOUT)..)
                           .maximum(:last_heartbeat_at)
      end
    end
  end
end
