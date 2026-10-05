# frozen_string_literal: true

module Analytics
  # Query object della dashboard analytics: incapsula tutte le aggregazioni di UN progetto+range su
  # Postgres (1 query ciascuna sull'indice [project_id, occurred_at]), condiviso da dashboard member,
  # stats API, canale CLI ed embed pubblico (logica nei service, controller thin — backend-channels).
  # I primitivi (BUCKETS/bucket_config/for_range) restano su Analytics::Pageview; qui vive la
  # composizione (fasi successive: filtri, sessioni, confronti periodo, conversioni).
  class Query
    # Colonne su cui la dashboard consente il filtro click-to-filter (allowlist: il nome colonna arriva
    # dal controller, mai dai params grezzi). Sono le dimensioni dei breakdown + path/referrer.
    FILTERABLE = (Pageview::BREAKDOWN_COLUMNS + %w[path referrer_host]).freeze

    # CYRA-500 — gli indirizzi che servono solo a controllare che il sito sia acceso: sono visite
    # vere ma non sono persone, e in cima alle pagine più viste gonfiano ogni totale. Restano nel
    # dato (nessuna cancellazione), si escludono dal conto salvo richiesta esplicita. I robot noti
    # non arrivano nemmeno: Analytics::Device li scarta all'ingresso.
    AUTOMATED_PATHS = %w[/up /up/ /health /health/ /healthz /healthz/ /ping /_health].freeze

    # Finestra e granularità della sparkline realtime (ultimi 30 minuti, un bucket al minuto).
    REALTIME_SERIES_MINUTES = 30

    def initialize(project_id:, range: Pageview::DEFAULT_RANGE, environment: nil, filters: {},
                   now: Time.current, include_automated: false)
      @project_id = project_id
      @range = Pageview::BUCKETS.key?(range) ? range : Pageview::DEFAULT_RANGE
      @environment = environment
      @filters = (filters || {}).stringify_keys.slice(*FILTERABLE).reject { |_, v| v.to_s.blank? }
      @now = now
      @include_automated = include_automated
    end

    # Serie temporale a doppio aggregato in 1 query date_bin: pageview totali + visitatori unici per
    # bucket. Ordinata vecchio→nuovo, i bucket senza traffico restano a zero. Ogni bucket porta `:at`
    # (istante d'inizio del blocco) per la label asse X e la finestra oraria del tooltip, come i
    # buckets di errori/metriche (Errors::Group.buckets_for). Il wire (Snapshot) proietta via a
    # `{pageviews, visitors}`: `:at` è interno alla vista, non al contratto pubblico.
    def timeseries
      cfg = Pageview.bucket_config(@range)
      since = @now - (cfg[:count] * cfg[:seconds])
      bin = date_bin_sql(cfg[:interval], since)

      rows = scope
               .group(Arel.sql(bin))
               .pluck(Arel.sql(bin), Arel.sql("COUNT(*)"), Arel.sql("COUNT(DISTINCT visitor_hash)"))

      result = Array.new(cfg[:count]) { |i| { at: since + (i * cfg[:seconds]), pageviews: 0, visitors: 0 } }
      rows.each do |bucket_time, pageviews, visitors|
        idx = ((bucket_time.to_time - since) / cfg[:seconds]).floor
        # Guardia difensiva irraggiungibile via test: la query filtra occurred_at in [since, now)
        # con date_bin d'origine `since` → idx è sempre in [0, count-1].
        # simplecov:disable
        next unless idx.between?(0, cfg[:count] - 1)

        result[idx] = { at: since + (idx * cfg[:seconds]), pageviews: pageviews, visitors: visitors }
        # simplecov:enable
      end
      result
    end

    # Top pagine del range: [{ path:, pageviews:, visitors: }] ordinate per volume.
    def top_paths(limit: 10)
      scope
        .group(:path)
        .order(Arel.sql("COUNT(*) DESC"))
        .limit(limit)
        .pluck(:path, Arel.sql("COUNT(*)"), Arel.sql("COUNT(DISTINCT visitor_hash)"))
        .map { |path, pageviews, visitors| { path: path, pageviews: pageviews, visitors: visitors } }
    end

    # Top referrer esterni del range (NULL = traffico diretto, escluso dalla lista).
    def top_referrers(limit: 10)
      scope
        .where.not(referrer_host: nil)
        .group(:referrer_host)
        .order(Arel.sql("COUNT(DISTINCT visitor_hash) DESC"))
        .limit(limit)
        .pluck(:referrer_host, Arel.sql("COUNT(DISTINCT visitor_hash)"))
        .map { |host, visitors| { referrer_host: host, visitors: visitors } }
    end

    # Breakdown per colonna (allowlist Pageview::BREAKDOWN_COLUMNS): [{ value:, visitors: }] per
    # visitatori unici, NULL escluso (UA sconosciuto / dimensione assente).
    def breakdown(column:, limit: 10)
      unless Pageview::BREAKDOWN_COLUMNS.include?(column.to_s)
        raise ArgumentError, "colonna breakdown non ammessa: #{column}"
      end

      scope
        .where.not(column => nil)
        .group(column)
        .order(Arel.sql("COUNT(DISTINCT visitor_hash) DESC"))
        .limit(limit)
        .pluck(column, Arel.sql("COUNT(DISTINCT visitor_hash)"))
        .map { |value, visitors| { value: value, visitors: visitors } }
    end

    def pageviews_count
      counts.first
    end

    def visitors_count
      counts.last
    end

    # % di visitatori con esattamente 1 pageview nel range (nil senza traffico). Ruby-side sul grouped
    # count: volumi da siti personali, nessuna necessità di window function.
    def bounce_rate
      counts = scope.group(:visitor_hash).count
      return nil if counts.empty?

      (counts.values.count(1) * 100.0 / counts.size).round
    end

    # Visitatori unici nella finestra realtime (chip "current visitors"), indipendente dal range.
    def realtime_count
      since = @now - Analytics::Constants::REALTIME_WINDOW
      s = apply_filters(Pageview.where(project_id: @project_id, name: Pageview::PAGEVIEW_NAME,
                                       occurred_at: since.., created_at: ::Ingest::EpochTime.insert_floor(since)..))
      s = s.where(environment: @environment) if @environment.present?
      s.distinct.count(:visitor_hash)
    end

    # Sparkline realtime: pageview per minuto negli ultimi REALTIME_SERIES_MINUTES (array di interi,
    # vecchio→nuovo, minuti senza traffico a zero).
    def realtime_series
      since = @now - REALTIME_SERIES_MINUTES.minutes
      bin = date_bin_sql("1 minute", since)
      s = apply_filters(Pageview.where(project_id: @project_id, name: Pageview::PAGEVIEW_NAME,
                                       occurred_at: since...@now, created_at: ::Ingest::EpochTime.insert_floor(since)..))
      s = s.where(environment: @environment) if @environment.present?
      counts = s.group(Arel.sql(bin)).pluck(Arel.sql(bin), Arel.sql("COUNT(*)")).to_h do |time, count|
        [ ((time.to_time - since) / 60).floor, count ]
      end
      Array.new(REALTIME_SERIES_MINUTES) { |i| counts[i].to_i }
    end

    # Conversioni di un goal nel range: { unique_conversions:, total_conversions:, conversion_rate: }.
    # unique = visitatori distinti che hanno convertito; rate = unique / visitatori totali del range
    # (nil senza traffico). Gli eventi candidati sono TUTTI gli eventi del range (pageview + custom),
    # ristretti dal goal.
    def conversions(goal)
      matched = goal.matching(events_scope)
      total, unique = matched.pick(Arel.sql("COUNT(*)"), Arel.sql("COUNT(DISTINCT visitor_hash)"))
      visitors = visitors_count
      rate = visitors.zero? ? nil : (unique * 100.0 / visitors).round(1)
      { unique_conversions: unique, total_conversions: total, conversion_rate: rate }
    end

    # Metriche di sessione (sessionizzazione query-time, gap ANALYTICS_SESSION_GAP): numero sessioni,
    # durata media (s), pageview per visita, bounce rate per-sessione (nil senza traffico).
    def session_summary
      row = Pageview.connection.select_one(<<~SQL.squish)
        #{sessions_cte},
        agg AS (
          SELECT COUNT(*) AS pv, MAX(occurred_at) - MIN(occurred_at) AS dur
          FROM sessions GROUP BY visitor_hash, session_num
        )
        SELECT COUNT(*) AS sessions,
               COALESCE(AVG(EXTRACT(EPOCH FROM dur)), 0) AS avg_duration,
               COALESCE(AVG(pv), 0) AS avg_pv,
               COALESCE(SUM(CASE WHEN pv = 1 THEN 1 ELSE 0 END)::numeric / NULLIF(COUNT(*), 0), 0) AS bounce
        FROM agg
      SQL
      sessions = row["sessions"].to_i
      {
        sessions: sessions,
        visit_duration: row["avg_duration"].to_f.round,
        views_per_visit: row["avg_pv"].to_f.round(1),
        bounce_rate: sessions.zero? ? nil : (row["bounce"].to_f * 100).round
      }
    end

    # Prime/ultime pagine di sessione, contate per sessione.
    def entry_pages(limit: 10) = session_pages("ASC", limit: limit)
    def exit_pages(limit: 10)  = session_pages("DESC", limit: limit)

    # Breakdown per canale di acquisizione (referrer + utm → Direct/Organic Search/Social/Referral/
    # Email/Paid/AI Assistants), classificato in Ruby su gruppi grezzi. [{ value:, visitors: }].
    def channels
      grouped = scope
                  .group(:referrer_host, :utm_medium, :utm_source)
                  .distinct.count(:visitor_hash)
      totals = Hash.new(0)
      grouped.each do |(referrer_host, utm_medium, utm_source), visitors|
        channel = Channel.classify(referrer_host: referrer_host, utm_medium: utm_medium, utm_source: utm_source)
        totals[channel] += visitors
      end
      totals.sort_by { |_, v| -v }.map { |value, visitors| { value: value, visitors: visitors } }
    end

    # Metriche di sintesi del range (per i chip e il confronto periodo).
    def summary
      { pageviews: pageviews_count, visitors: visitors_count }
    end

    # CYRA-500 — le cinque metriche di testa nella stessa forma per il periodo corrente e per quello
    # precedente: «quanto» da solo non risponde a «come va», che è una domanda comparativa.
    def headline
      session = session_summary
      { pageviews: pageviews_count, visitors: visitors_count, bounce_rate: session[:bounce_rate],
        visit_duration: session[:visit_duration], views_per_visit: session[:views_per_visit] }
    end

    # La stessa interrogazione, spostata sul periodo immediatamente precedente. Porta con sé filtri e
    # scelta sulle visite automatiche: un confronto fra due insiemi diversi direbbe una cosa falsa.
    def previous_query
      cfg = Pageview.bucket_config(@range)
      since = @now - (cfg[:count] * cfg[:seconds])
      self.class.new(project_id: @project_id, range: @range, environment: @environment,
                     filters: @filters, now: since, include_automated: @include_automated)
    end

    # Confronto col periodo precedente allineato (stesso span immediatamente prima): { current:, previous: }.
    def comparison
      { current: summary, previous: previous_query.summary }
    end

    private

    # Una nuova lettura dello snapshot può riusare gli stessi filtri, ma non i totali di
    # quella precedente: nel frattempo possono essere arrivate altre visite.
    def initialize_copy(other)
      super
      @counts = nil
    end

    # Tutti i pannelli della richiesta condividono lo stesso snapshot: un solo giro sullo
    # scope, anche quando headline/summary/conversioni chiedono nuovamente gli stessi totali.
    def counts
      @counts ||= scope.pick(Arel.sql("COUNT(*)"), Arel.sql("COUNT(DISTINCT visitor_hash)"))
    end

    # CTE base della sessionizzazione: marca l'inizio di sessione (gap > soglia o primo evento del
    # visitatore) e propaga un progressivo di sessione. Solo eventi di traffico (name = pageview).
    def sessions_cte
      gap = Analytics::Constants::SESSION_GAP.to_i
      <<~SQL.strip
        WITH marked AS (
          SELECT visitor_hash, occurred_at, path,
            CASE WHEN LAG(occurred_at) OVER w IS NULL
                      OR occurred_at - LAG(occurred_at) OVER w > interval '#{gap} seconds'
                 THEN 1 ELSE 0 END AS new_session
          FROM analytics_pageviews
          WHERE #{session_where}
          WINDOW w AS (PARTITION BY visitor_hash ORDER BY occurred_at)
        ),
        sessions AS (
          SELECT visitor_hash, occurred_at, path,
            SUM(new_session) OVER (PARTITION BY visitor_hash ORDER BY occurred_at) AS session_num
          FROM marked
        )
      SQL
    end

    def session_pages(order, limit:)
      rows = Pageview.connection.select_all(<<~SQL.squish)
        #{sessions_cte},
        edge AS (
          SELECT DISTINCT ON (visitor_hash, session_num) path
          FROM sessions ORDER BY visitor_hash, session_num, occurred_at #{order}
        )
        SELECT path, COUNT(*) AS sessions FROM edge GROUP BY path ORDER BY COUNT(*) DESC LIMIT #{limit.to_i}
      SQL
      rows.map { |r| { path: r["path"], sessions: r["sessions"].to_i } }
    end

    # WHERE sanitizzato (bind) condiviso dalle query di sessione: progetto, traffico, range, environment.
    def session_where
      cfg = Pageview.bucket_config(@range)
      since = @now - (cfg[:count] * cfg[:seconds])
      conditions = [ "project_id = ? AND name = ? AND occurred_at >= ? AND occurred_at < ? AND created_at >= ?",
                     @project_id, Pageview::PAGEVIEW_NAME, since, @now, ::Ingest::EpochTime.insert_floor(since) ]
      unless @include_automated
        conditions[0] += " AND path NOT IN (?)"
        conditions << AUTOMATED_PATHS
      end
      if @environment.present?
        conditions[0] += " AND environment = ?"
        conditions << @environment
      end
      # Filtri dashboard: i nomi colonna vengono dall'allowlist FILTERABLE (safe interpolarli), i valori
      # restano bind parameter.
      @filters.each do |col, val|
        conditions[0] += " AND #{col} = ?"
        conditions << val
      end
      Pageview.sanitize_sql_array(conditions)
    end

    # Scope del TRAFFICO (metriche pageview): solo gli eventi name = "pageview".
    def scope
      events_scope.where(name: Pageview::PAGEVIEW_NAME)
    end

    # Tutti gli eventi del range (pageview + custom), filtrati: base per le conversioni dei goal.
    def events_scope
      relation = apply_filters(Pageview.for_range(@project_id, @range, environment: @environment, now: @now))
      @include_automated ? relation : relation.where.not(path: AUTOMATED_PATHS)
    end

    # Applica i filtri dashboard (allowlist FILTERABLE) a una relation Analytics::Pageview.
    def apply_filters(relation)
      @filters.reduce(relation) { |rel, (col, val)| rel.where(col => val) }
    end

    def date_bin_sql(interval, since)
      conn = Pageview.connection
      "date_bin(#{conn.quote(interval)}::interval, occurred_at, #{conn.quote(since)}::timestamptz)"
    end
  end
end
