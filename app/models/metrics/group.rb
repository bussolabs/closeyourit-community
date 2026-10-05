# frozen_string_literal: true

module Metrics
  # Signature deduplicata: tutte le occorrenze con lo stesso fingerprint, in un progetto, sono UN
  # gruppo. Contatori e aggregati di durata aggiornati atomicamente da Metrics::Ingest::Record.
  class Group < ApplicationRecord
    belongs_to :project, class_name: "Projects::Project", inverse_of: :metric_groups
    belongs_to :ticket, class_name: "Ticketing::Ticket", optional: true
    has_many :samples, class_name: "Metrics::Sample", foreign_key: :group_id,
             inverse_of: :group, dependent: :destroy

    # Vocabolario fisso (discriminator polimorfico: ogni kind ha forma propria) → enum legittimo.
    # performance_issue = verdetto aggregato (N+1, slow request, slow external HTTP); `subtype` lo qualifica.
    enum :kind, { slow_query: 0, slow_method: 1, performance_issue: 2 }, prefix: true
    # CYRA-45: stato di triage gestito dall'operatore (workflow tecnico) → enum legittimo, speculare a
    # Errors::Group.status. reopen riporta a unresolved (da resolved o ignored). Vedi Metrics::Triage.
    enum :status, { unresolved: 0, resolved: 1, ignored: 2 }, prefix: true

    validates :fingerprint, presence: true, uniqueness: { scope: :project_id }
    validates :title, presence: true
    validates :kind, presence: true

    scope :recent, -> { order(last_seen_at: :desc) }
    # CYRA-339: ordine per costo complessivo (durata totale = media × occorrenze, mantenuta atomicamente
    # in duration_total_ms). Mette in cima il collo di bottiglia vero, non il picco raro capitato una o
    # due volte. Chiave secondaria samples_count: i verdetti COUNT_BASED_SUBTYPES pesano per NUMERO di
    # occorrenze e hanno duration_ms=0 per contratto → a durata pari (0) i più frequenti emergono nella
    # loro fascia invece di finire in fondo in ordine arbitrario; il loro peso resta leggibile nella
    # colonna Occorrenze (ordinabile). Restano comunque sotto i gruppi con durata reale: "costo di tempo"
    # e "costo di frequenza" non sono commensurabili, e la DoD ordina per tempo complessivo. Tie-breaker
    # id per paginazione deterministica.
    # CYRA-367 — una singola operazione oltre il minuto quasi sempre non è la sua durata ma
    # un'attesa in coda misurata male (616 secondi per un INSERT non è una query lenta). La soglia
    # è DICHIARATA, non derivata: da qui in su il valore si mostra come sospetto, non come fatto.
    SUSPECT_DURATION_MS = 60_000

    def suspect_duration? = average_duration_ms.to_f >= SUSPECT_DURATION_MS

    # L'etichetta leggibile della riga (solo per le query: gli altri kind hanno già un titolo umano).
    def query_label = @query_label ||= Metrics::QueryLabel.new(title)

    scope :costliest_first, -> { order(duration_total_ms: :desc, samples_count: :desc, id: :desc) }
    scope :performance_issues, -> { kind_performance_issue }

    # Facet del kind performance_issue (verdetti aggregati). Allineato ai subtype emessi dai client.
    # Ruby/server: n_plus_one, high_query_count, slow_request, slow_external_http.
    # Mobile (Dart): repeated_http (N chiamate identiche in finestra), jank (frame oltre budget),
    # rebuild_storm (widget ricostruito troppe volte).
    PERFORMANCE_SUBTYPES = %w[
      n_plus_one high_query_count slow_request slow_external_http
      repeated_http jank rebuild_storm
    ].freeze

    # Subtype "a conteggio": il verdetto pesa per NUMERO di occorrenze, non per durata — il campione
    # arriva con duration_ms=0. La sua soglia è sul conteggio (già applicata a monte da
    # Metrics::Ingest::Record#notify_alerts via project.performance_alert_threshold), MAI sulla durata.
    # Gli altri performance_issue (n_plus_one, slow_request, slow_external_http, jank) portano una
    # durata reale e restano gatati da Alerting::Rule#threshold_ms in Alerting::Evaluate#threshold_match?.
    COUNT_BASED_SUBTYPES = %w[repeated_http rebuild_storm high_query_count].freeze

    # Chart "durata nel tempo": stesso schema dell'uptime (date_bin Postgres, una query, niente N+1).
    RANGES = { "30m" => 30.minutes, "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days }.freeze
    DEFAULT_RANGE = "24h"

    BUCKETS = {
      "30m" => { count: 30, interval: "1 minute",   seconds: 60 },
      "24h" => { count: 48, interval: "30 minutes", seconds: 1_800 },
      "7d"  => { count: 56, interval: "3 hours",     seconds: 10_800 },
      "30d" => { count: 30, interval: "1 day",       seconds: 86_400 }
    }.freeze

    # Soglie di durata media (ms) per la classificazione cromatica dei blocchi. Sono i valori di
    # SISTEMA: il progetto può sostituirli (CYRA-341, Metrics::Thresholds) — nessuno legga più questi
    # numeri come l'unica verità.
    FAST_MS = 150
    MEDIUM_MS = 500

    # CYRA-339: sotto questo numero di occorrenze la media aritmetica non è un segnale (1-2 campioni la
    # distorcono). Le righe con meno di così sono marcate «pochi campioni» come poco significative.
    LOW_SAMPLE_THRESHOLD = 20

    # CYRA-146: percentili di durata esposti nel dettaglio. p50 mediana, p95/p99 i casi peggiori che
    # la media nasconde. Sigle tecniche standard riusate come chiave (intero) → valore ms.
    PERCENTILES = [ 50, 95, 99 ].freeze

    def self.range_duration(key) = RANGES.fetch(key, RANGES[DEFAULT_RANGE])
    def self.bucket_config(range) = BUCKETS.fetch(range, BUCKETS[DEFAULT_RANGE])

    # Lunghezza reale della finestra di un range: quella dei BLOCCHI del grafico, non quella nominale
    # di RANGES — le due coincidono, ma il confronto col periodo precedente deve allinearsi ai
    # blocchi disegnati, non a un valore parallelo che un domani potrebbe divergere.
    def self.window_seconds(range)
      cfg = bucket_config(range)
      cfg[:count] * cfg[:seconds]
    end

    # Durata media aggregata per blocco temporale, per N gruppi in 1 query (date_bin).
    # Ritorna { group_id => [ {status:, count:, avg_ms:, at:}, ... count ] } ordinato vecchio→nuovo;
    # i blocchi senza occorrenza restano :empty. status per soglia: avg<150 :fast · <500 :medium · ≥500 :slow.
    # `at:` = istante d'inizio del blocco (per label asse X e finestra oraria del tooltip in vista).
    def self.buckets_for(group_ids, range, now = Time.current, thresholds: nil)
      cfg = bucket_config(range)
      ids = Array(group_ids).uniq
      return {} if ids.blank?

      since = now - (cfg[:count] * cfg[:seconds])
      conn = connection
      bin = "date_bin(#{conn.quote(cfg[:interval])}::interval, occurred_at, #{conn.quote(since)}::timestamptz)"
      rows = Metrics::Sample.where(group_id: ids, occurred_at: since...now)
                            .group(Arel.sql("group_id"), Arel.sql(bin))
                            .pluck(Arel.sql("group_id"), Arel.sql(bin),
                                   Arel.sql("COUNT(*)"), Arel.sql("AVG(duration_ms)"))

      result = ids.index_with { Array.new(cfg[:count]) { |i| { status: :empty, count: 0, avg_ms: nil, at: since + (i * cfg[:seconds]) } } }
      rows.each do |gid, bucket_time, count, avg|
        # round, non floor: `since` ha i nanosecondi e il bin torna dal DB al microsecondo, un soffio prima.
        idx = ((bucket_time.to_time - since) / cfg[:seconds]).round
        # Guardie difensive irraggiungibili via test: (1) idx è sempre in [0, count-1] perché la query
        # filtra occurred_at in [since, now) con date_bin d'origine `since`; (2) `avg` (AVG(duration_ms))
        # non è mai nil per un bucket non vuoto — duration_ms è NOT NULL.
        # simplecov:disable
        next unless idx.between?(0, cfg[:count] - 1)

        result[gid][idx] = { status: duration_status(avg, thresholds), count: count, avg_ms: avg&.round, at: since + (idx * cfg[:seconds]) }
        # simplecov:enable
      end
      result
    end

    # CYRA-341 — «sta peggiorando?» chiede la DURATA nel tempo, non quante volte è successo: due
    # giorni con lo stesso numero di occorrenze disegnavano lo stesso identico grafico anche quando
    # l'operazione ci metteva il doppio. Un blocco per intervallo con p50 (il caso tipico) e p95 (la
    # coda che la media nasconde), UNA query con date_bin + percentile_cont per un solo gruppo.
    # Blocchi senza campioni: p50/p95 nil e status :empty — mai uno zero che si legge come «veloce».
    def self.duration_buckets_for(group_id, range, now = Time.current, thresholds: nil)
      cfg = bucket_config(range)
      since = now - (cfg[:count] * cfg[:seconds])
      conn = connection
      bin = "date_bin(#{conn.quote(cfg[:interval])}::interval, occurred_at, #{conn.quote(since)}::timestamptz)"
      rows = Metrics::Sample.where(group_id: group_id, occurred_at: since...now)
                            .group(Arel.sql(bin))
                            .pluck(Arel.sql(bin), Arel.sql("COUNT(*)"),
                                   Arel.sql("percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms)"),
                                   Arel.sql("percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms)"))

      buckets = Array.new(cfg[:count]) { |i| { status: :empty, count: 0, p50: nil, p95: nil, at: since + (i * cfg[:seconds]) } }
      rows.each do |bucket_time, count, p50, p95|
        # round, non floor: `since` ha i nanosecondi e il bin torna dal DB al microsecondo, un soffio prima.
        idx = ((bucket_time.to_time - since) / cfg[:seconds]).round
        next unless idx.between?(0, cfg[:count] - 1)

        buckets[idx] = { status: duration_status(p95, thresholds), count: count,
                         p50: p50&.round, p95: p95&.round, at: since + (idx * cfg[:seconds]) }
      end
      buckets
    end

    # Fascia di colore di una durata (ms) secondo le soglie in vigore: quelle del progetto quando
    # arrivano (Metrics::Thresholds), altrimenti i valori di sistema.
    def self.duration_status(value, thresholds = nil)
      return :empty if value.nil?

      fast = thresholds&.dig(:fast) || FAST_MS
      slow = thresholds&.dig(:slow) || MEDIUM_MS
      value = value.to_f
      return :fast if value < fast
      return :medium if value < slow

      :slow
    end

    # CYRA-341 — la durata media della finestra corrente e di quella PRECEDENTE della stessa
    # lunghezza (ultime 24 ore contro le 24 prima), in una query sola. Ritorna sempre le tre chiavi:
    # `delta_pct` è nil quando il confronto non esiste — nessun campione prima, o un periodo
    # precedente a durata zero. Un delta inventato è peggio di nessun delta.
    def duration_trend(range = DEFAULT_RANGE, now = Time.current)
      span = self.class.window_seconds(range)
      since = now - span
      current, previous = samples.where(occurred_at: (since - span)...now)
                                 .pick(*[ ">=", "<" ].map { |op| window_avg_sql(op, since) })
      { current_ms: current&.round, previous_ms: previous&.round,
        delta_pct: delta_pct(current, previous) }
    end

    def average_duration_ms
      count = samples_count.to_i
      return 0.0 if count.zero?

      duration_total_ms.to_f / count
    end

    # CYRA-339: la media su pochi campioni è rumore → la riga va segnalata come poco significativa.
    def low_sample? = samples_count.to_i < LOW_SAMPLE_THRESHOLD

    # Percentili di durata (ms) calcolati ON-DEMAND dai campioni conservati, via percentile_cont Postgres
    # in UNA query. Ritorna { 50 => ms, 95 => ms, 99 => ms } (nil per ogni sigla se non ci sono campioni).
    #
    # DECISIONE (CYRA-146, technical analysis "calcolare al rollup?"): NON si persistono al rollup. I
    # percentili sono statistiche d'ordine, non aggregabili con l'UPDATE atomico incrementale che tiene
    # avg/min/max sul gruppo (Metrics::Ingest::Record#bump_group!) — richiederebbero un t-digest o un job
    # periodico + colonne + backfill, complessità non giustificata. Calcolarli dai sample è esatto,
    # coerente con .buckets_for (che pure aggrega on-demand) e reversibile (nessuna migration).
    # TRADE-OFF: coprono la finestra di retention dei sample (Metrics::PruneSamplesJob, oggi 14g), mentre
    # avg/min/max sono cumulativi lifetime sul gruppo — è la scelta più azionabile (i rallentamenti
    # RECENTI che la media nasconde). Potati tutti i campioni → nil (la vista mostra "—"). Per-gruppo:
    # NON esposto nel serializer di lista né nella index (sarebbe un percentile per riga = N+1).
    # La frazione finisce dentro Arel.sql, che disattiva ogni controllo a valle: passa quindi da
    # sanitize_sql_array, così nel frammento può finire solo un numero — qualunque cosa arrivi come
    # argomento. Difesa in profondità: oggi i percentili vengono da PERCENTILES, non dall'utente.
    def duration_percentiles(percentiles = PERCENTILES)
      exprs = percentiles.map do |p|
        Arel.sql(self.class.sanitize_sql_array(
                   [ "percentile_cont(?) WITHIN GROUP (ORDER BY duration_ms)", Float(p).fdiv(100) ]
                 ))
      end
      percentiles.zip(Array(samples.pick(*exprs))).to_h
    end

    # True se il verdetto è a conteggio (vedi COUNT_BASED_SUBTYPES): la sua soglia è sul numero di
    # occorrenze, non sulla durata del campione — che per questi subtype è sempre 0.
    def count_based? = COUNT_BASED_SUBTYPES.include?(subtype)

    def promoted? = ticket_id.present?

    private

    # AVG(duration_ms) della sola metà indicata della finestra (`>=` corrente, `<` precedente).
    # L'istante finisce dentro Arel.sql, che disattiva ogni controllo a valle: passa da
    # sanitize_sql_array, così nel frammento può entrare solo un timestamp quotato.
    def window_avg_sql(operator, since)
      Arel.sql(self.class.sanitize_sql_array(
                 [ "AVG(duration_ms) FILTER (WHERE occurred_at #{operator} ?)", since ]
               ))
    end

    # Variazione percentuale arrotondata; nil quando non c'è un confronto onesto da fare (niente
    # prima, o un periodo precedente a durata zero — che darebbe una divisione per zero).
    def delta_pct(current, previous)
      return nil if current.nil? || previous.nil? || previous.to_f.zero?

      ((current.to_f - previous.to_f) * 100.0 / previous.to_f).round
    end
  end
end
