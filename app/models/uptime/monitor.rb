# frozen_string_literal: true

module Uptime
  # Monitor HTTP di un progetto: viene pingato su schedule; al cambio di salute apre/chiude un incident.
  # current_status è salute gestita dal sistema (workflow tecnico) → enum legittimo (rules/lookup-tables.md).
  class Monitor < ApplicationRecord
    self.table_name = "uptime_monitors"

    belongs_to :project, class_name: "Projects::Project", inverse_of: :uptime_monitors
    # 1 monitor per [progetto, environment]; l'environment dev'essere DICHIARATO dal progetto (subset).
    belongs_to :environment, class_name: "Types::Environment", inverse_of: :uptime_monitors
    belongs_to :created_by, class_name: "Accounts::Account", optional: true
    # Gruppo di monitor (org-level, opzionale, MUTABILE): raggruppa la dashboard + status page unica.
    belongs_to :group, class_name: "Uptime::Group", optional: true, inverse_of: :monitors
    # Solo i ping raw: gli aggregati (hourly/daily) vivono nella STESSA tabella ma NON devono comparire
    # in `monitor.checks` (RecordCheck, pannello "check recenti", incident transition restano raw-only e
    # invariati). `create!` via questa associazione imposta granularity=check (scope_for_create). Gli
    # aggregati orfani alla destroy del monitor sono coperti dalla FK on_delete: :cascade (non da dependent).
    has_many :checks, -> { where(granularity: :check) }, class_name: "Uptime::Check",
             foreign_key: :monitor_id, inverse_of: :monitor, dependent: :destroy
    has_many :incidents, class_name: "Uptime::Incident", foreign_key: :monitor_id,
             inverse_of: :monitor, dependent: :destroy
    # Banner pubblico (uno per monitor, opt-in): manutenzioni/avvisi sulla status page.
    has_one :announcement, class_name: "Uptime::Announcement", foreign_key: :monitor_id,
            inverse_of: :monitor, dependent: :destroy

    enum :current_status, { unknown: 0, up: 1, down: 2 }, prefix: :status

    # Tipo di check (CYRA-151): http (default, url) o servizi non-web via host(+port). Workflow tecnico
    # scelto dall'utente alla creazione → enum legittimo. tcp = porta aperta; dns = l'host risolve;
    # ping = l'host risponde all'ICMP echo.
    enum :check_type, { http: 0, tcp: 1, dns: 2, ping: 3 }, prefix: :check_type

    # Finestre temporali del selettore (default 24h). 1y = vista SLA aggregata.
    RANGES = { "30m" => 30.minutes, "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days, "1y" => 365.days }.freeze
    DEFAULT_RANGE = "24h"

    def self.range_duration(key) = RANGES.fetch(key, RANGES[DEFAULT_RANGE])

    # % uptime per monitor sulla finestra [since, now], in 1 query grouped. `source` sceglie la tabella:
    # :raw (COUNT sui ping) per le finestre brevi, :hourly/:daily (SUM dei bucket) per quelle lunghe, dove
    # il raw è già stato potato. { monitor_id => percent|nil }; nil se nessun dato nella finestra.
    def self.uptime_percents(monitor_ids, since, source: :raw)
      ids = Array(monitor_ids).uniq
      return {} if ids.blank?

      rel, total_sql, up_sql = source_aggregation(source)
      # simplecov:disable total (COUNT/SUM di un GROUP con dati) ≥ 1 → il ramo `nil` è irraggiungibile qui
      rel.where(monitor_id: ids, checked_at: since..)
         .group(:monitor_id)
         .pluck(:monitor_id, Arel.sql(total_sql), Arel.sql(up_sql))
         .to_h { |id, total, up| [ id, total.to_i.zero? ? nil : (up.to_f / total * 100).round(2) ] }
      # simplecov:enable
    end

    # % uptime per monitor su PIÙ finestre SLA (30m/24h/7d/30d/1y) in UNA sola query: ogni finestra ha una
    # coppia di colonne FILTER che porta la SUA sorgente (granularity) + il suo `since`. Così COUNT sui ping
    # (raw) e SUM sui bucket (hourly/daily) convivono senza loop → niente N+1 (le query per-sorgente avrebbero
    # fingerprint identico su hourly/daily). windows = { key => since (Time) } → { monitor_id => { key => %|nil } }.
    def self.uptime_percents_for_windows(monitor_ids, windows)
      ids = Array(monitor_ids).uniq
      return {} if ids.blank? || windows.blank?

      conn = connection
      keys = windows.keys
      cols = keys.flat_map do |key|
        q = conn.quote(windows[key])
        source = bucket_config(key)[:source]
        [ Arel.sql(window_total_sql(source, q)), Arel.sql(window_up_sql(source, q)) ]
      end
      rows = Uptime::Check.where(monitor_id: ids, checked_at: windows.values.min..)
                          .group(:monitor_id).pluck(:monitor_id, *cols)
      rows.each_with_object({}) do |row, acc|
        mid = row.shift
        acc[mid] = keys.each_with_index.to_h do |key, i|
          total, up = row[i * 2].to_i, row[(i * 2) + 1].to_i
          [ key, total.zero? ? nil : (up.to_f / total * 100).round(2) ]
        end
      end
    end

    # Blocchi (segmenti) della timeline per range: quanti, durata e SORGENTE. Tassellano [now - count*durata, now].
    #   30m → 30×1min · 24h → 48×30min (raw) | 7d → 56×3h · 30d → 30×1g (hourly) | 1y → 365×1g (daily)
    # Il raw copre solo le finestre brevi (retention corta); le lunghe leggono i rollup persistiti.
    BUCKETS = {
      "30m" => { count: 30,  interval: "1 minute",   seconds: 60,     source: :raw },
      "24h" => { count: 48,  interval: "30 minutes", seconds: 1_800,  source: :raw },
      "7d"  => { count: 56,  interval: "3 hours",    seconds: 10_800, source: :hourly },
      "30d" => { count: 30,  interval: "1 day",      seconds: 86_400, source: :hourly },
      "1y"  => { count: 365, interval: "1 day",      seconds: 86_400, source: :daily }
    }.freeze

    def self.bucket_config(range) = BUCKETS.fetch(range, BUCKETS[DEFAULT_RANGE])

    # Stato AGGREGATO per blocco temporale, per N monitor in 1 query (date_bin Postgres, niente N+1).
    # Legge dalla sorgente del range (:raw COUNT sui ping · :hourly/:daily SUM sui bucket). Ritorna
    # { monitor_id => [ {status:, total:, up:, avg_ms:}, ... count ] } vecchio→nuovo; blocchi senza dati
    # restano :empty. Per :daily l'ULTIMO blocco (oggi, non ancora nel daily notturno) è sovrapposto dagli
    # hourly di oggi, così la barra annuale non ha un buco sul giorno corrente.
    def self.buckets_for(monitor_ids, range, now = Time.current)
      cfg = bucket_config(range)
      ids = Array(monitor_ids).uniq
      return {} if ids.blank?

      since = now - (cfg[:count] * cfg[:seconds])
      result = fill_buckets(ids, cfg, since, now)
      overlay_today!(result, ids, cfg, now) if cfg[:source] == :daily
      result
    end

    # --- read path interni -------------------------------------------------------------------------

    # Relazione + espressioni SQL (total, up, avg) per sorgente: :raw conta i ping, :hourly/:daily sommano
    # i contatori dei bucket (avg = media pesata sugli up: SUM(avg*up)/SUM(up)).
    def self.source_aggregation(source)
      if source == :raw
        [ Uptime::Check.granularity_check, "COUNT(*)", "COUNT(*) FILTER (WHERE up)",
          "AVG(response_time_ms) FILTER (WHERE up)" ]
      else
        [ Uptime::Check.where(granularity: source), "SUM(checks_total)", "SUM(checks_up)",
          "SUM(avg_response_ms * checks_up)::float / NULLIF(SUM(checks_up), 0)" ]
      end
    end
    private_class_method :source_aggregation

    # date_bin grouped nella sorgente del range → array di `count` blocchi, vuoti pre-inizializzati.
    def self.fill_buckets(ids, cfg, since, now)
      conn = connection
      rel, total_sql, up_sql, avg_sql = source_aggregation(cfg[:source])
      bin = "date_bin(#{conn.quote(cfg[:interval])}::interval, checked_at, #{conn.quote(since)}::timestamptz)"
      rows = rel.where(monitor_id: ids, checked_at: since...now)
                .group(Arel.sql("monitor_id"), Arel.sql(bin))
                .pluck(Arel.sql("monitor_id"), Arel.sql(bin),
                       Arel.sql(total_sql), Arel.sql(up_sql), Arel.sql(avg_sql))
      result = ids.index_with { Array.new(cfg[:count]) { { status: :empty, total: 0, up: 0, avg_ms: nil } } }
      rows.each do |mid, bucket_time, total, up, avg_ms|
        # round, non floor: `since` ha i nanosecondi e il bin torna dal DB al microsecondo, un soffio prima.
        idx = ((bucket_time.to_time - since) / cfg[:seconds]).round
        # simplecov:disable idx ∈ [0, count-1] garantito dal filtro `since...now` + bin coerenti → `next` irraggiungibile
        next unless idx.between?(0, cfg[:count] - 1)
        # simplecov:enable
        result[mid][idx] = build_bucket(total, up, avg_ms)
      end
      result
    end
    private_class_method :fill_buckets

    # Ultimo blocco (oggi) della vista annuale: il daily notturno non l'ha ancora scritto → lo si compone
    # dagli hourly di oggi (ultime 24h). Nessun doppio conteggio: la riga daily di oggi non esiste ancora.
    def self.overlay_today!(result, ids, cfg, now)
      last_start = now - cfg[:seconds]
      _rel, total_sql, up_sql, avg_sql = source_aggregation(:hourly)
      Uptime::Check.where(granularity: :hourly, monitor_id: ids, checked_at: last_start...now)
                   .group(:monitor_id)
                   .pluck(:monitor_id, Arel.sql(total_sql), Arel.sql(up_sql), Arel.sql(avg_sql))
                   .each { |mid, total, up, avg_ms| result[mid][cfg[:count] - 1] = build_bucket(total, up, avg_ms) }
    end
    private_class_method :overlay_today!

    # Stato + contatori di un blocco con dati (total ≥ 1). :empty è l'init a monte, non passa di qui.
    def self.build_bucket(total, up, avg_ms)
      total = total.to_i
      up = up.to_i
      status = up == total ? :up : (up.zero? ? :down : :partial)
      { status: status, total: total, up: up, avg_ms: avg_ms&.round }
    end
    private_class_method :build_bucket

    # Colonne FILTER per finestra: portano granularity (la sorgente) + il since, così UNA sola query copre
    # tutte le sorgenti. raw = COUNT sui ping; hourly/daily = SUM sui contatori dei bucket.
    def self.window_total_sql(source, quoted_since)
      cond = "#{granularity_cond(source)} AND checked_at >= #{quoted_since}::timestamptz"
      source == :raw ? "COUNT(*) FILTER (WHERE #{cond})" : "SUM(checks_total) FILTER (WHERE #{cond})"
    end
    private_class_method :window_total_sql

    def self.window_up_sql(source, quoted_since)
      cond = "#{granularity_cond(source)} AND checked_at >= #{quoted_since}::timestamptz"
      source == :raw ? "COUNT(*) FILTER (WHERE #{cond} AND up)" : "SUM(checks_up) FILTER (WHERE #{cond})"
    end
    private_class_method :window_up_sql

    def self.granularity_cond(source)
      key = source == :raw ? "check" : source.to_s
      "granularity = #{Uptime::Check.granularities.fetch(key)}"
    end
    private_class_method :granularity_cond

    HTTP_METHODS = %w[GET HEAD POST].freeze

    # Tetto della soglia di conferma: oltre, il ritardo con cui un guasto vero viene annunciato
    # supererebbe il rumore che la soglia toglie (10 controlli × intervallo minimo = 10 minuti).
    MAX_FAILURE_THRESHOLD = 10

    normalizes :url, with: ->(value) { value.strip }
    normalizes :name, with: ->(value) { value.to_s.strip }
    normalizes :http_method, with: ->(value) { value.to_s.strip.upcase }
    # host case-insensitive (i FQDN lo sono): strip + downcase. apply_to_nil è false di default → per i
    # monitor http (host nil) la lambda non gira, nessun crash.
    normalizes :host, with: ->(value) { value.strip.downcase }

    # name auto-derivato da "progetto · environment": il form non lo chiede (l'identità del monitor è
    # la coppia [progetto, environment], 1 per env). Senza questo ogni create da UI falliva su :name.
    before_validation :set_default_name
    # url e metodo HTTP valgono solo per i monitor http; i check non-web usano host(+port).
    validates :url, presence: true, format: { with: %r{\Ahttps?://.+\z}i }, if: :check_type_http?
    validate :public_http_address, if: -> { check_type_http? && (new_record? || will_save_change_to_url?) }
    validates :http_method, inclusion: { in: HTTP_METHODS }, if: :check_type_http?
    # host obbligatorio per i check non-web (tcp/dns/ping); porta solo per tcp (1..65535).
    validates :host, presence: true, unless: :check_type_http?
    validates :port, presence: true,
              numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535 },
              if: :check_type_tcp?
    validates :interval_seconds, :expected_status, :timeout_seconds,
              numericality: { only_integer: true, greater_than: 0 }
    # Quanti controlli falliti DI FILA servono per dichiarare il sito irraggiungibile (CYRA-776).
    # 1 = il comportamento di prima (si apre al primo inciampo). Il tetto non è estetico: la soglia
    # moltiplica l'intervallo, e una cifra battuta male (100) renderebbe il monitor muto per ore
    # senza che nessuno se ne accorga — è l'avviso stesso che sparisce.
    validates :failure_threshold,
              numericality: { only_integer: true, greater_than: 0,
                              less_than_or_equal_to: MAX_FAILURE_THRESHOLD }
    validates :environment_id, uniqueness: { scope: :project_id, message: :monitor_exists }
    # nil = check scadenza certificato disattivo.
    validates :ssl_expiry_warn_days, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    # nil = avviso di lentezza disattivo (come ssl_expiry_warn_days). Millisecondi oltre cui un check UP
    # ma lento genera l'avviso uptime_slow.
    validates :latency_threshold_ms, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    # La keyword richiede un body: HEAD non ne ha.
    validates :expected_body_keyword, absence: { message: :keyword_needs_body }, if: -> { http_method == "HEAD" }
    validate :environment_declared_by_project
    # L'uptime (HTTP-ping) ha senso solo su piattaforme web/server: niente monitor sui progetti solo-mobile.
    # Solo alla creazione, come la capability qui sotto: è un requisito di AMMISSIONE, non un invariante
    # da rivalidare per sempre. RecordCheck salva il monitor a OGNI ping (last_checked_at, stato), quindi
    # una validazione viva sull'update fa fallire la transazione e il check non viene mai scritto — con
    # l'uptime page ferma e nessun segnale all'utente. In produzione ha prodotto 1.440 fallimenti al
    # giorno (uno al minuto, la cadenza del dispatcher) dal 29 giugno al 7 luglio 2026, finché qualcuno
    # non ha rimesso a posto il progetto a mano.
    validate :project_supports_uptime, on: :create
    # Capability per-ambiente: l'uptime dev'essere abilitato (risolto default+override) su [progetto, ambiente].
    # Solo alla creazione: disabilitare la capability DOPO non invalida i monitor esistenti.
    validate :uptime_capability_enabled, on: :create
    # Il gruppo è org-level: dev'essere della STESSA organizzazione del progetto del monitor (tenant-integrity).
    validate :group_must_match_organization

    # Tolleranza del dispatcher: `Uptime::DispatchChecksJob` gira ogni minuto e scrive `last_checked_at`
    # qualche secondo DOPO il tick. Con intervallo == cadenza del dispatcher (60s) la maturità cade poco
    # oltre il tick successivo → il monitor viene saltato per un giro e ripreso solo al tick dopo →
    # intervallo effettivo raddoppiato (120s, "no data" a blocchi alterni nello status page). Considerare
    # "due" anche un monitor che matura entro la prossima mezza cadenza elimina il drift (al più un check
    # leggermente anticipato, innocuo). MAI ≥ cadenza piena, altrimenti un monitor verrebbe pingato 2×.
    DISPATCH_GRACE = 30.seconds

    # Cadenza del dispatcher (`config/recurring.yml`, ogni minuto): un monitor non viene mai pingato più
    # spesso di così, per quanto piccolo sia `interval_seconds`. È il PAVIMENTO dell'intervallo effettivo
    # usato dalla staleness qui sotto — MAI legarlo al polling di Solid Queue, che è un'altra cosa.
    DISPATCH_CADENCE = 60

    # Quanti intervalli effettivi senza check rendono il dato "vecchio": oltre, lo stato MOSTRATO diventa
    # `unknown` invece dell'ultimo up/down (CYRA-209). Col worker dei controlli fermo nessun ping avanza
    # `last_checked_at`, e l'ultimo verde resterebbe lì all'infinito, ingannevole. 3 come i server host
    # (`SERVERS_STALE_AFTER_SECONDS` = 180 = 3 push mancati): tre giri saltati = motore verosimilmente fermo.
    STALE_AFTER_INTERVALS = 3

    scope :active, -> { where(active: true) }
    scope :ordered, -> { order(:name) }
    # Monitor con status page pubblica attiva (opt-in). Usato dal canale web pubblico (Website::).
    scope :public_status, -> { where(public_status_enabled: true) }
    # Monitor "scaduti" da pingare: attivi, mai controllati o con ultimo check oltre l'intervallo.
    # `now` come bind (Time.current) → testabile con travel_to; l'intervallo è per-riga (Postgres).
    # `+ DISPATCH_GRACE` anticipa di mezza cadenza la maturità per evitare il drift a 2× intervallo.
    scope :due, lambda { |now = Time.current|
      active.where("last_checked_at IS NULL OR last_checked_at + (interval_seconds * interval '1 second') <= ?", now + DISPATCH_GRACE)
    }
    # Istante di SCADENZA del dato: `last_checked_at + N intervalli effettivi`. L'intervallo effettivo è
    # per-riga (`GREATEST(interval_seconds, cadenza)`, così un interval piccolo non scende sotto la cadenza
    # del dispatcher). Stessa forma additiva di `due` (l'interval sta col last_checked_at, `?` a destra →
    # inferito timestamp). Le due costanti sono INTERI nostri, non input → interpolazione sicura.
    STALE_DEADLINE_SQL = "last_checked_at + " \
                         "(GREATEST(interval_seconds, #{DISPATCH_CADENCE}) * #{STALE_AFTER_INTERVALS} * interval '1 second')"

    # Monitor col dato "vecchio" (stale): attivi, controllati almeno una volta, ma scaduti (deadline < now)
    # → vanno MOSTRATI unknown e NON contati come up/down. In pausa ≠ stale (non ci si aspetta il ping) e
    # mai-controllato ≠ stale (è già unknown, non un verde ingannevole). `fresh` è l'esatto complemento —
    # insieme partizionano l'intera tabella per i conteggi stale-aware.
    scope :stale, lambda { |now = Time.current|
      active.where("last_checked_at IS NOT NULL AND #{STALE_DEADLINE_SQL} < ?", now)
    }
    scope :fresh, lambda { |now = Time.current|
      where("active = FALSE OR last_checked_at IS NULL OR #{STALE_DEADLINE_SQL} >= ?", now)
    }

    # Filtro per stato VISUALIZZATO (display_status), non persistito → coerente con la pill mostrata: un
    # monitor stale (persistito up/down) è mostrato unknown, quindi deve comparire filtrando "unknown" e
    # sparire filtrando "up"/"down" (CYRA-209). `wanted` = sottoinsieme di current_statuses.keys; vuoto o
    # completo → nessun filtro. `up`/`down` richiedono il dato fresco; `unknown` = persistito unknown OR stale.
    def self.for_display_statuses(wanted, now = Time.current)
      wanted = Array(wanted).map(&:to_s).uniq & current_statuses.keys
      return all if wanted.empty? || wanted.size == current_statuses.size

      fresh_sql = "(active = FALSE OR last_checked_at IS NULL OR #{STALE_DEADLINE_SQL} >= :now)"
      stale_sql = "(active = TRUE AND last_checked_at IS NOT NULL AND #{STALE_DEADLINE_SQL} < :now)"
      parts = []
      parts << "(current_status = #{current_statuses['up']} AND #{fresh_sql})" if wanted.include?("up")
      parts << "(current_status = #{current_statuses['down']} AND #{fresh_sql})" if wanted.include?("down")
      parts << "(current_status = #{current_statuses['unknown']} OR #{stale_sql})" if wanted.include?("unknown")
      where(sanitize_sql_array([ parts.join(" OR "), { now: now } ]))
    end

    # Ordinamento "salute prima" (CYRA-492): in cima i siti NON sani — prima i giù reali (down mostrato),
    # poi il dato incerto (unknown mostrato: persistito unknown OPPURE dato vecchio), infine i sani. Non
    # impone un secondo criterio: a parità di stato decide l'ordine appeso da chi chiama (di norma il nome).
    # Stale-aware come display_status (l'ordine WHEN conta: un down col dato vecchio non matcha il ramo 0,
    # cade nel ramo incerto), così un verde ingannevole non resta sopra un guasto reale. I monitor in pausa
    # contano come sani: non sono un guasto in corso (la riga li mostra "Paused"). `now` bind per travel_to.
    def self.health_order(now = Time.current)
      order(Arel.sql(sanitize_sql_array([ health_order_sql, { now: now } ])))
    end

    def self.health_order_sql
      down = current_statuses.fetch("down")
      unknown = current_statuses.fetch("unknown")
      fresh = "last_checked_at IS NOT NULL AND #{STALE_DEADLINE_SQL} >= :now"
      stale = "last_checked_at IS NOT NULL AND #{STALE_DEADLINE_SQL} < :now"
      "CASE " \
        "WHEN active AND current_status = #{down} AND (#{fresh}) THEN 0 " \
        "WHEN active AND (current_status = #{unknown} OR (#{stale})) THEN 1 " \
        "ELSE 2 END"
    end
    private_class_method :health_order_sql

    def open_incident = incidents.find_by(resolved_at: nil)
    # Incident di primo livello (i raggruppati collassano nel loro primary), più recenti prima.
    def top_incidents = incidents.top_level.recent
    # Banner pubblico attivo ORA (o nil se assente/spento/fuori finestra). Gate della status page.
    def current_announcement
      announcement if announcement&.live?
    end
    def paused? = !active?
    # Status page pubblica attiva? (gate del canale Website::). Opt-in, default false.
    def public? = public_status_enabled?

    # Bersaglio leggibile del check, per tipo: http → url; tcp → host:porta; dns/ping → host. Usato in
    # presentazione (riga/lista/show) e negli avvisi al posto di `url`, che è popolato solo per http.
    def target
      case check_type.to_sym
      when :http then url
      when :tcp then "#{host}:#{port}"
      else host
      end
    end

    # Finestra oltre cui il dato è vecchio: N intervalli effettivi (l'intervallo non scende mai sotto la
    # cadenza del dispatcher, così un `interval_seconds` piccolo non anticipa lo stale).
    def stale_after = [ interval_seconds, DISPATCH_CADENCE ].max * STALE_AFTER_INTERVALS

    # Il dato del monitor è vecchio? (worker dei controlli probabilmente fermo). In pausa o mai-controllato
    # → no (vedi scope `stale`). È una valutazione a LETTURA: non scrive nulla, funziona anche a worker fermo.
    def stale?(now = Time.current)
      return false unless active?
      return false if last_checked_at.nil?

      last_checked_at < now - stale_after
    end

    # Stato da MOSTRARE: `unknown` quando il dato è vecchio (l'ultimo up/down sarebbe un verde ingannevole),
    # altrimenti lo stato persistito. Da usare in ogni punto di presentazione al posto di `current_status`.
    def display_status(now = Time.current)
      stale?(now) ? :unknown : current_status.to_sym
    end

    private

    # Reject obvious private destinations before saving; the checker still validates DNS at runtime.
    def public_http_address
      uri = URI.parse(url.to_s)
      return if DevelopmentLab.address(uri, organization: project&.organization)

      hostname = uri.hostname.to_s.downcase.delete_suffix(".")
      return errors.add(:url, :invalid) if hostname.blank?

      blocked = if NetworkGuard.ip_literal?(hostname)
        NetworkGuard.blocked_address?(hostname)
      else
        hostname == "localhost" || hostname.end_with?(".localhost", ".local", ".internal")
      end
      errors.add(:url, I18n.t("member.review_fixes.public_url_required")) if blocked
    rescue URI::InvalidURIError
      errors.add(:url, :invalid)
    end

    def environment_declared_by_project
      return if project.blank? || environment.blank?

      errors.add(:environment, :invalid) unless project.environment_ids.include?(environment_id)
    end

    def project_supports_uptime
      return if project.blank?

      errors.add(:project, :uptime_unsupported) unless project.supports_uptime?
    end

    # Legge il flag RISOLTO (default ambiente + eventuale override del progetto) dalla riga join, che
    # esiste sempre al create perché environment_declared_by_project la garantisce (no-op se assente).
    def uptime_capability_enabled
      return if project.blank? || environment.blank?

      link = project.project_environments.find_by(environment_id: environment_id)
      errors.add(:base, :uptime_disabled) if link && !link.uptime_enabled?
    end

    def group_must_match_organization
      return if group.blank? || project.blank?

      errors.add(:group, :invalid) if group.organization_id != project.organization_id
    end

    # "Progetto · Environment" quando il name non è fornito (caso normale: il form non ha campo name).
    def set_default_name
      return if name.present?

      self.name = [ project&.name, environment&.label ].compact.join(" · ").presence
    end
  end
end
