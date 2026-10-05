# frozen_string_literal: true

module Ops
  # Salute dei GIRI RICORRENTI (i task di config/recurring.yml), terzo segnale del motore dei job
  # accanto a Ops::WorkerLiveness (i processi battono) e Ops::QueueThroughput (la coda smaltisce).
  #
  # Perché serve (CYRA-752): su staging non c'è un worker dedicato, i job girano dentro Puma e Sablier
  # addormenta il contenitore appena nessuno lo usa. Con Puma fermo è fermo anche lo Scheduler: i giri
  # ricorrenti non partivano mai, quindi una regressione su di essi restava invisibile fino alla
  # produzione — l'unico ambiente in cui quei giri girano davvero.
  #
  # I due segnali sono INDIPENDENTI, per la stessa ragione di CYRA-299: lo Scheduler può battere
  # l'heartbeat e non accodare niente (task scartati perché invalidi, thread di scheduling morto). Il
  # battito dice che il processo c'è; solo le righe in `solid_queue_recurring_executions` dicono che
  # quel processo sta facendo il suo lavoro.
  class RecurringSchedule
    # Allineata a Ops::WorkerLiveness: oltre questa età senza battito è lo stesso Solid Queue a
    # considerare morto un processo.
    HEARTBEAT_TIMEOUT = 5.minutes

    # I giri più fitti scattano ogni minuto, quindi dieci minuti senza un accodamento sono un guasto,
    # non una pausa. La soglia sta larga di proposito: `clear_solid_queue_finished_jobs` pota ogni ora
    # i job finiti e la chiave esterna cancella A CASCATA anche le righe degli accodamenti, per cui
    # subito dopo la potatura l'ultimo accodamento visibile può essere nessuno finché non scatta il
    # giro del minuto successivo.
    STALE_THRESHOLD = 10.minutes

    # Solid Queue registra `kind` = nome della classe demodulizzato. Chi ACCODA i giri è lo Scheduler:
    # guardare un processo qualunque non basta, perché coi soli Worker vivi la coda si smaltisce ma
    # nessun giro ricorrente ci arriva più.
    SCHEDULER_KIND = "Scheduler"

    class << self
      # Does this environment have recurring tasks? Asked to the same configuration the supervisor uses
      # to start a Scheduler: production (staging included) and development have them (CYRA-932).
      def configured?
        SolidQueue::Configuration.new.configured_processes.any? { |process| process.kind == :scheduler }
      end

      # Battito più recente fra gli Scheduler ancora vivi, o nil se nessuno batte.
      def last_heartbeat_at(now: Time.current)
        SolidQueue::Process.where(kind: SCHEDULER_KIND, last_heartbeat_at: (now - HEARTBEAT_TIMEOUT)..)
                           .maximum(:last_heartbeat_at)
      end

      # Ultimo giro ricorrente davvero accodato. È il MASSIMO su tutti i task: dice che il motore
      # accoda, NON che un giro in particolare sia scattato. Chi vuole quella risposta guarda gli
      # spec del giro o i suoi log — qui si sorveglia il motore.
      def last_run_at = SolidQueue::RecurringExecution.maximum(:run_at)

      # Da quanti secondi. Serve a chi legge da fuori per distinguere un accodamento avvenuto ADESSO
      # da uno rimasto lì da prima: la sveglia post-rilascio (CYRA-752) trova il contenitore appena
      # ripartito, e senza questo confronto scambierebbe l'accodamento fatto durante il deploy per la
      # prova che lo Scheduler sta ancora lavorando.
      def last_run_age_seconds(now: Time.current)
        run_at = last_run_at
        return nil if run_at.blank?

        [ (now - run_at).to_i, 0 ].max
      end

      # Quanti giri lo Scheduler ha registrato all'avvio: dato di lettura, non un verdetto — le righe
      # restano anche a Scheduler fermo.
      def registered_count = SolidQueue::RecurringTask.static.count

      # :disabled (nessun giro dichiarato qui) · :down (nessuno Scheduler vivo) · :stale (vivo ma non
      # accoda) · :up.
      def status(now: Time.current)
        return :disabled unless configured?
        return :down if last_heartbeat_at(now:).blank?

        run_at = last_run_at
        return :stale if run_at.blank? || run_at < now - STALE_THRESHOLD

        :up
      end
    end
  end
end
