# frozen_string_literal: true

module Valhalla
  # Segnali di salute tecnica del sistema per il cruscotto /valhalla/health: query object dedicato
  # (gemello di Valhalla::DashboardSignals) per tenere thin l'HealthController. Tre gruppi, DUE
  # connessioni DIVERSE (limite multi-database, niente JOIN cross-db):
  #   CODE/FALLITI — SolidQueue::* gira sul DB queue (solid_queue.connects_to in config/environments).
  #   TABELLE      — SQL raw su ApplicationRecord.connection (il PRIMARY), non sulla connessione queue.
  #   SERVIZI      — nessuna query qui: legge lo snapshot che Valhalla::ProbeServicesJob scrive in
  #                  Solid Cache (le probe sincrone in request bloccherebbero Puma, vedi quel job).
  class SystemHealth
    # Top-N tabelle per dimensione: abbastanza per vedere cosa cresce senza affogare la card.
    TOP_TABLES_LIMIT = 10

    SERVICE_CACHE_KEY = "valhalla:service_health"
    SERVICE_KEYS = %i[embedding telegram github email llm].freeze

    QueueBacklog = Data.define(:queue_name, :count)
    FailedBreakdown = Data.define(:class_name, :count)
    TableSize = Data.define(:table, :size_bytes, :size_pretty, :est_rows)
    # status: :up, :down, :unconfigured, :unverifiable (scritti da ProbeServices) o :unknown (job mai
    # girato/chiave assente dallo snapshot — MAI un crash, la pagina resta renderizzabile).
    # :unverifiable è il «non lo so» del mittente email (CYRA-771): la sonda non ha potuto chiedere,
    # e non è un guasto da dipingere di rosso.
    #
    # Dal CYRA-765 i servizi qui sono TUTTI di sistema, con una chiave sola: i conteggi delle
    # organizzazioni collegate (CYRA-549) non hanno più nessuno che li scriva e sono usciti dal Data.
    ServiceStatus = Data.define(:key, :status, :checked_at, :detail)

    # `now`/`top_tables_limit` iniettabili per i test (coerenza con DashboardSignals).
    def initialize(now: Time.current, top_tables_limit: TOP_TABLES_LIMIT)
      @now = now
      @top_tables_limit = top_tables_limit
    end

    # --- CODE (DB queue) ---

    def ready_backlog
      SolidQueue::ReadyExecution.group(:queue_name).count
                                 .map { |queue_name, count| QueueBacklog.new(queue_name:, count:) }
                                 .sort_by { |row| -row.count }
    end

    def ready_total = SolidQueue::ReadyExecution.count
    def scheduled_total = SolidQueue::ScheduledExecution.count
    def claimed_total = SolidQueue::ClaimedExecution.count
    def blocked_total = SolidQueue::BlockedExecution.count

    # Liveness del motore dei job: riusa Ops::WorkerLiveness (stessa soglia/semantica di
    # WorkersHealthController) invece di ridefinire la query — distingue "coda ferma perché nessun
    # worker" da "tutto ok, il worker sta smaltendo".
    def workers_alive? = Ops::WorkerLiveness.alive?(now: @now)
    def last_worker_heartbeat_at = Ops::WorkerLiveness.last_heartbeat_at(now: @now)
    def workers_count = SolidQueue::Process.where(kind: Ops::WorkerLiveness::EXECUTOR_KIND).count

    # --- FALLITI (DB queue) ---

    def failed_total = SolidQueue::FailedExecution.count

    def failed_breakdown
      SolidQueue::FailedExecution.joins(:job).group("solid_queue_jobs.class_name").count
                                  .map { |class_name, count| FailedBreakdown.new(class_name:, count:) }
                                  .sort_by { |row| -row.count }
    end

    # --- TABELLE IN CRESCITA (primary, NON la connessione queue) ---

    def growing_tables
      rows = ApplicationRecord.connection.select_all(<<~SQL.squish)
        SELECT c.relname AS table_name,
               pg_total_relation_size(c.oid) AS size_bytes,
               COALESCE(s.n_live_tup, 0) AS est_rows
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
        WHERE c.relkind = 'r' AND n.nspname = 'public'
        ORDER BY pg_total_relation_size(c.oid) DESC
        LIMIT #{@top_tables_limit.to_i}
      SQL

      rows.map do |row|
        size_bytes = row["size_bytes"].to_i
        TableSize.new(
          table: row["table_name"],
          size_bytes:,
          size_pretty: ActiveSupport::NumberHelper.number_to_human_size(size_bytes),
          est_rows: row["est_rows"].to_i
        )
      end
    end

    # --- SERVIZI ESTERNI (Solid Cache, scritto da Valhalla::ProbeServicesJob) ---

    def service_statuses
      by_key = Array(Rails.cache.read(SERVICE_CACHE_KEY)).index_by { |entry| entry[:key].to_s }

      SERVICE_KEYS.map do |key|
        entry = by_key[key.to_s]
        next ServiceStatus.new(key:, status: :unknown, checked_at: nil, detail: nil) unless entry

        ServiceStatus.new(key:, status: entry[:status].to_sym, checked_at: entry[:checked_at],
                          detail: entry[:detail])
      end
    end
  end
end
