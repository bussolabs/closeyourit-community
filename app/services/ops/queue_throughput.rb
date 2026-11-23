# frozen_string_literal: true

module Ops
  # Throughput del MOTORE DEI JOB (Solid Queue), gemello di Ops::WorkerLiveness (CYRA-299). Il
  # battito dei processi Worker (WorkerLiveness) non basta: un worker vivo può comunque non smaltire
  # nulla — è successo con la coda dichiarata come stringa in `queue.yml` (vedi CLAUDE.md), che ha
  # fermato tutti i job in produzione per due giorni senza un solo errore e senza che l'heartbeat se
  # ne accorgesse.
  #
  # Il giudizio è PER CORSIA (CYRA-1229): una corsia è un pool di worker di config/queue.yml con le
  # sue code e i suoi thread. Guardando tutte le code insieme, una corsia ferma restava nascosta
  # finché un'altra finiva qualcosa — e l'unica regola globale non poteva distinguere un
  # addestramento di un'ora da un blocco. Una corsia è ferma quando il suo lavoro pronto più vecchio
  # aspetta da oltre la sua soglia E nessun suo job è finito dentro la stessa soglia.
  class QueueThroughput
    # Soglia delle corsie rapide. Coerente con la cadenza dei cron ricorrenti (1-15', vedi
    # config/recurring.yml): assorbe qualche ciclo di polling/dispatch perso senza generare un falso
    # allarme durante deploy/restart worker. È anche quella che fa scattare il caso «tutto fermo».
    STALL_THRESHOLD = 10.minutes

    # Corsia dei lavori lunghi (batch, ai): un addestramento dura fino a un'ora e la corsia ha un
    # thread solo, quindi il job dietro può aspettarlo tutto senza che niente sia guasto.
    LONG_JOBS_STALL_THRESHOLD = 90.minutes

    # Corsia SEO: un giro può durare fino a Seo::Crawl::MAX_DURATION (2 ore), un thread solo.
    SEO_STALL_THRESHOLD = 150.minutes

    # Le code che allargano la soglia della loro corsia. Una corsia prende la soglia più larga fra le
    # sue code: un job lungo occupa il thread anche per le code che gli stanno davanti.
    QUEUE_STALL_THRESHOLDS = {
      "batch" => LONG_JOBS_STALL_THRESHOLD,
      "ai" => LONG_JOBS_STALL_THRESHOLD,
      "seo" => SEO_STALL_THRESHOLD
    }.freeze

    class << self
      # Stallo GLOBALE, rimasto come informazione e per il manuale: c'è lavoro pronto da qualche parte
      # e niente è finito da STALL_THRESHOLD. NON decide più verde o rosso: annullerebbe le soglie
      # lunghe dopo dieci minuti. Coda vuota non è mai stallo: assenza di lavoro non è distinguibile
      # da guasto guardando solo il timestamp.
      def stalled?(now: Time.current, ready_count: self.ready_count, last_finished_at: self.last_finished_at)
        ready_count.positive? && (last_finished_at.nil? || last_finished_at < now - STALL_THRESHOLD)
      end

      def ready_count = SolidQueue::ReadyExecution.count

      def last_finished_at = SolidQueue::Job.where.not(finished_at: nil).maximum(:finished_at)

      # I nomi delle corsie ferme, nell'ordine di config/queue.yml. Il nome è l'elenco delle code
      # unite da "+" (`batch+ai`): la virgola resta fuori, perché in queue.yml una virgola dentro un
      # nome è proprio il guasto che ha fermato tutto.
      #
      # Senza lavoro pronto oltre la soglia la corsia non è mai ferma, per quanto vecchio sia il suo
      # ultimo job finito: i job finiti si conservano solo un'ora (config/application.rb), quindi su
      # una corsia lunga «nulla finito» da solo vorrebbe dire soltanto «nulla ricordato».
      def stalled_lanes(now: Time.current, lanes: self.lanes,
                        oldest_ready_at: oldest_ready_at_by_queue, last_finished_at: last_finished_at_by_queue)
        lanes.filter_map do |selectors|
          limit = now - threshold_for(selectors)
          oldest = times_for(oldest_ready_at, selectors).min
          last = times_for(last_finished_at, selectors).max

          lane_name(selectors) if oldest && oldest < limit && (last.nil? || last < limit)
        end
      end

      # Le corsie dei pool di worker, lette dalla configurazione già interpretata da Solid Queue come
      # fa Ops::RecurringQueueCoverage.worker_queues. `configured_processes` ripete un pool per ogni
      # processo (`processes: 2` → due voci): la corsia è una sola.
      def lanes
        SolidQueue::Configuration.new
                                 .configured_processes
                                 .select { |process| process.kind.to_sym == :worker }
                                 .map { |process| Array(process.attributes[:queues]).map(&:to_s) }
                                 .uniq
      end

      def lane_name(selectors) = selectors.join("+")

      def threshold_for(selectors)
        selectors.map { |selector| QUEUE_STALL_THRESHOLDS.fetch(selector, STALL_THRESHOLD) }.max || STALL_THRESHOLD
      end

      def oldest_ready_at_by_queue = SolidQueue::ReadyExecution.group(:queue_name).minimum(:created_at)

      def last_finished_at_by_queue
        SolidQueue::Job.where.not(finished_at: nil).group(:queue_name).maximum(:finished_at)
      end

      private

      # Gli orari delle code servite da una corsia. `*` e `prefisso*` si leggono come li legge Solid
      # Queue, alla stessa maniera di Ops::RecurringQueueCoverage.covered?.
      def times_for(times_by_queue, selectors)
        times_by_queue.filter_map { |queue, time| time if selectors.any? { |selector| serves?(selector, queue.to_s) } }
      end

      def serves?(selector, queue)
        return true if selector == "*"
        return queue.start_with?(selector.delete_suffix("*")) if selector.end_with?("*")

        selector == queue
      end
    end
  end
end
