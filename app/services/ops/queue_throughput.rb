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

    # Tetto del conteggio dei lavori pronti riportato da /up/workers (CYRA-1273). Oltre questo numero
    # la coda è comunque «piena» per chi indaga, e il costo della domanda resta fisso e piccolo.
    READY_COUNT_CAP = 10_000

    class << self
      # Lo stallo lo decide solo stalled_lanes, corsia per corsia (CYRA-1229): lo stallo globale non
      # aveva più chiamanti ed è stato tolto (CYRA-1273).
      #
      # I lavori pronti, contati fino a READY_COUNT_CAP e non oltre (CYRA-1273): l'endpoint è pubblico
      # e contare tutta la coda a ogni chiamata costava di più proprio a coda piena. Il conteggio
      # esatto resta dalla console (docs/runbooks/workers-down.md).
      def ready_count = SolidQueue::ReadyExecution.limit(READY_COUNT_CAP).count

      def ready_count_capped?(count = ready_count) = count >= READY_COUNT_CAP

      def last_finished_at = SolidQueue::Job.where.not(finished_at: nil).maximum(:finished_at)

      # I nomi delle corsie ferme, nell'ordine di config/queue.yml. Il nome è l'elenco delle code
      # unite da "+" (`batch+ai`): la virgola resta fuori, perché in queue.yml una virgola dentro un
      # nome è proprio il guasto che ha fermato tutto.
      #
      # Senza lavoro pronto oltre la soglia la corsia non è mai ferma, per quanto vecchio sia il suo
      # ultimo job finito: i job finiti si conservano solo un'ora (config/application.rb), quindi su
      # una corsia lunga «nulla finito» da solo vorrebbe dire soltanto «nulla ricordato».
      def stalled_lanes(now: Time.current, lanes: self.lanes,
                        oldest_ready_at: oldest_ready_at_by_queue(lanes),
                        last_finished_at: last_finished_at_by_queue(lanes))
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

      # Da quando aspetta il lavoro in testa a ogni coda: quello che il worker reclamerebbe per primo,
      # nello stesso ordine (priority, job_id) e quindi sullo stesso indice (index_solid_queue_poll_by_queue)
      # con cui lo cerca Solid Queue. Una riga per coda, non tutta la coda: con 600000 lavori arretrati
      # un MIN(created_at) raggruppato li leggeva tutti a ogni chiamata, perché created_at non sta in
      # nessun indice (CYRA-1273). Su una corsia ferma la testa non cambia, quindi invecchia oltre la
      # soglia come il lavoro più vecchio.
      def oldest_ready_at_by_queue(lanes = self.lanes)
        names, patterns = queue_selectors(lanes)
        return SolidQueue::ReadyExecution.group(:queue_name).minimum(:created_at) if patterns.any?

        head_by_queue(names, SolidQueue::ReadyExecution.where("solid_queue_ready_executions.queue_name = queues.name")
                                                       .order(:priority, :job_id).select(:created_at))
      end

      # L'ultimo job finito di ogni coda, letto all'indietro sull'indice (queue_name, finished_at): una
      # riga per coda anche con la tabella piena di job in attesa (CYRA-1273).
      def last_finished_at_by_queue(lanes = self.lanes)
        names, patterns = queue_selectors(lanes)
        return SolidQueue::Job.where.not(finished_at: nil).group(:queue_name).maximum(:finished_at) if patterns.any?

        head_by_queue(names, SolidQueue::Job.where("solid_queue_jobs.queue_name = queues.name")
                                            .where.not(finished_at: nil).order(finished_at: :desc).select(:finished_at))
      end

      private

      # I nomi esatti delle code delle corsie, e i selettori con `*`. Una coda per nome si legge dalla
      # sua testa; con `*` o `prefisso*` i nomi veri si sanno solo leggendo la tabella, quindi si torna
      # alla domanda raggruppata — config/queue.yml oggi elenca solo nomi esatti.
      def queue_selectors(lanes) = lanes.flatten.uniq.partition { |selector| !selector.end_with?("*") }

      # Una sola domanda per tutte le code: per ogni nome, la prima riga di `head`. Le code senza riga
      # restano fuori, come nella domanda raggruppata.
      def head_by_queue(names, head)
        return {} if names.empty?

        sql = ActiveRecord::Base.sanitize_sql_array(
          [ "SELECT queues.name, (#{head.limit(1).to_sql}) FROM unnest(ARRAY[?]::varchar[]) AS queues(name)", names ]
        )
        SolidQueue::Record.with_connection { |connection| connection.select_all(sql).cast_values.to_h.compact }
      end

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
