# frozen_string_literal: true

module Metrics
  # Le BARRE dei due grafici di un gruppo — occorrenze nel tempo e durata nel tempo — nella forma che
  # Ui::HistogramComponent si aspetta. La finestra oraria e il drill-down arrivano da chart_bar
  # (Monitoring::ChartsHelper): un solo costruttore di barra per errori e metriche (CYRA-742).
  module ChartsHelper
    # Classe del blocco chart (literal, no interpolazione Tailwind) per status del bucket.
    BUCKET_CLASSES = {
      fast: "bg-emerald-300", medium: "bg-amber-300", slow: "bg-red-400", empty: "bg-stone-200/80 dark:bg-zinc-700/80"
    }.freeze
    def metric_bucket_class(status) = BUCKET_CLASSES.fetch(status, BUCKET_CLASSES[:empty])

    def metric_bucket_title(bucket)
      return t("member.metrics.bucket.no_data") if bucket[:status] == :empty

      "#{metric_duration_label(bucket[:avg_ms])} · #{bucket[:count]} occ"
    end

    # Altezza % della barra dell'istogramma occorrenze: ∝ count rispetto al picco del range.
    # 0 → 0 (il minimo visibile 6px per i blocchi vuoti è gestito nella vista); non-zero ha minimo 4%.
    def metric_bucket_height(count, max)
      return 0 if count.to_i.zero? || max.to_i.zero?

      [ (count * 100.0 / max).round, 4 ].max
    end

    # View-model delle barre per Ui::HistogramComponent (metriche): colore per performance (status),
    # riga valore = "avg ms · N occ" (o "nessun dato" per i blocchi vuoti). Riusa chart_bar
    # (Monitoring::ChartsHelper) per finestra, tooltip e — drill-down CYRA-46 — href/active del blocco.
    def metric_chart_bars(buckets, max, range, bucket_href: nil, active_from: nil, active_to: nil)
      buckets = Array(buckets)
      seconds = ::Metrics::Group.bucket_config(range)[:seconds]
      buckets.map do |b|
        empty = b[:count].to_i.zero?
        chart_bar(b, seconds, range, empty:, bucket_href:, active_from:, active_to:,
                  value_line: metric_bucket_title(b),
                  color_class: metric_bucket_class(b[:status]),
                  height: empty ? 6 : metric_bucket_height(b[:count], max))
      end
    end

    # CYRA-341 — riga valore del tooltip del grafico durata: il caso tipico (p50) e la coda (p95).
    def metric_duration_bucket_title(bucket)
      return t("member.metrics.bucket.no_data") if bucket[:status] == :empty

      "p50 #{metric_duration_label(bucket[:p50])} · p95 #{metric_duration_label(bucket[:p95])}"
    end

    # View-model delle barre del grafico «Durata nel tempo»: altezza ∝ p95 rispetto al picco del
    # periodo, colore dalla fascia di soglia, tooltip con p50 e p95. Nessun drill-down: cliccare un
    # blocco filtra le occorrenze e quel gesto resta sull'istogramma delle occorrenze, uno solo.
    def metric_duration_bars(buckets, max, range)
      seconds = ::Metrics::Group.bucket_config(range)[:seconds]
      Array(buckets).map do |b|
        empty = b[:status] == :empty
        chart_bar(b, seconds, range, empty:, bucket_href: nil, active_from: nil, active_to: nil,
                  value_line: metric_duration_bucket_title(b),
                  color_class: metric_bucket_class(b[:status]),
                  height: empty ? 6 : metric_bucket_height(b[:p95], max))
      end
    end
  end
end
