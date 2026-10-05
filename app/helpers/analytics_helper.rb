# frozen_string_literal: true

module AnalyticsHelper
  # Altezza % della barra dell'istogramma pageview: ∝ pageviews rispetto al picco del range.
  # 0 → 0 (il minimo visibile per i bucket vuoti è gestito nella vista); non-zero ha minimo 4%.
  def analytics_bucket_height(count, max)
    return 0 if count.to_i.zero? || max.to_i.zero?

    [ (count * 100.0 / max).round, 4 ].max
  end

  def analytics_bucket_title(bucket)
    return t("member.monitoring.analytics.bucket.no_data") if bucket[:pageviews].to_i.zero?

    t("member.monitoring.analytics.bucket.tooltip", pageviews: bucket[:pageviews], visitors: bucket[:visitors])
  end

  # View-model delle barre per Ui::HistogramComponent (pageview): altezza ∝ pageviews, colore indigo
  # uniforme (blocchi vuoti = traccia grigia con stub 6%), riga valore = visitatori unici del bucket.
  # Riusa chart_bucket_window (Monitoring::ChartsHelper) per la finestra oraria del tooltip — stesso pattern di
  # error_chart_bars / metric_chart_bars.
  def analytics_chart_bars(buckets, max, range)
    buckets = Array(buckets)
    seconds = Analytics::Pageview.bucket_config(range)[:seconds]
    buckets.map do |b|
      empty = b[:pageviews].to_i.zero?
      {
        height: empty ? 6 : analytics_bucket_height(b[:pageviews], max),
        color_class: empty ? "bg-stone-200 dark:bg-zinc-700" : "bg-indigo-500",
        empty: empty,
        time_label: chart_bucket_window(b[:at], seconds, range),
        value_line: t("member.monitoring.analytics.tooltip_visitors", count: b[:visitors].to_i)
      }
    end
  end

  # Larghezza % della barra orizzontale di una riga breakdown (top pages/referrer/browser/UTM).
  def analytics_row_width(value, max)
    return 0 if value.to_i.zero? || max.to_i.zero?

    [ (value * 100.0 / max).round, 3 ].max
  end

  def analytics_bounce_label(rate)
    rate.nil? ? "—" : "#{rate}%"
  end

  # Bandiera emoji da un country code ISO alpha-2 (IT → 🇮🇹) via regional indicator symbols.
  # Stringa vuota se il codice non è due lettere A-Z.
  def analytics_country_flag(code)
    normalized = code.to_s.upcase
    return "" unless normalized.match?(/\A[A-Z]{2}\z/)

    normalized.each_char.map { |c| 0x1F1E6 + c.ord - "A".ord }.pack("U*")
  end

  # Durata media della visita, formato compatto ("1m 30s" / "45s"). 0 → "0s".
  def analytics_duration_label(seconds)
    total = seconds.to_i
    minutes, secs = total.divmod(60)
    minutes.zero? ? "#{secs}s" : "#{minutes}m #{secs}s"
  end

  # Variazione % vs periodo precedente ("+12%" / "−5%"); nil se non confrontabile (precedente 0).
  def analytics_delta_label(current, previous)
    return nil if previous.to_i.zero?

    delta = ((current.to_i - previous.to_i) * 100.0 / previous.to_i).round
    "#{delta.positive? ? '+' : ''}#{delta}%".tr("-", "−")
  end

  # CYRA-500 — le date vere del periodo mostrato. «ultimi 1y · 52 intervalli» non dice da quando a
  # quando, e su un arco che attraversa il capodanno l'anno non compariva da nessuna parte.
  def analytics_window_label(buckets, range)
    blocks = Array(buckets)
    starts_at = blocks.first&.dig(:at)
    return t("member.monitoring.analytics.timeline_sub", range: range, count: blocks.size) if starts_at.blank?

    seconds = Analytics::Pageview.bucket_config(range)[:seconds]
    ends_at = (blocks.last[:at] || starts_at) + seconds
    t("member.monitoring.analytics.timeline_window",
      from: l(starts_at.to_date, format: :day_month_year), to: l(ends_at.to_date, format: :day_month_year))
  end

  # CYRA-500 — variazione rispetto al periodo precedente, per le cinque metriche di testa. nil
  # quando il confronto non esiste (nessun dato prima): un delta inventato è peggio di nessun delta.
  # `lower_is_better` decide il COLORE, non il segno — meno rimbalzi è una buona notizia, più visite
  # non è né buona né cattiva senza sapere cosa si voleva, e allora resta grigia.
  def analytics_trend(current, previous, lower_is_better: nil)
    return nil if previous.blank? || previous.to_f.zero? || current.nil?

    delta = ((current.to_f - previous.to_f) * 100.0 / previous.to_f).round
    { label: analytics_trend_label(delta), color: analytics_trend_color(delta, lower_is_better) }
  end

  def analytics_trend_label(delta)
    return t("member.monitoring.analytics.comparison.flat") if delta.zero?

    "#{delta.positive? ? '▲' : '▼'} #{delta.abs}%"
  end

  def analytics_trend_color(delta, lower_is_better)
    return :gray if lower_is_better.nil? || delta.zero?

    improving = lower_is_better ? delta.negative? : delta.positive?
    improving ? :emerald : :rose
  end

  # URL della dashboard con un filtro click-to-filter aggiunto/sostituito (preserva progetto, range,
  # environment e gli altri filtri attivi).
  def analytics_filter_url(column, value)
    member_monitoring_analytics_path(request.query_parameters.merge(column.to_s => value))
  end

  # URL della dashboard senza il filtro indicato (badge "×").
  def analytics_unfilter_url(column)
    member_monitoring_analytics_path(request.query_parameters.except(column.to_s))
  end

  # Etichetta leggibile di una colonna filtrabile (i18n con fallback humanize).
  def analytics_filter_label(column)
    t("member.monitoring.analytics.filters.#{column}", default: column.to_s.humanize)
  end

  # CYRA-497 — i canali di acquisizione nascono come nomi inglesi ("Organic Social", "Direct"):
  # sono il valore CANONICO del dato, uguale fra dashboard pubblica e area member, e come tale
  # resta. Qui si traduce solo l'etichetta che si legge, con il nome originale come riserva per un
  # canale nuovo che non abbia ancora la sua parola.
  def analytics_channel_label(value)
    key = value.to_s.parameterize(separator: "_")
    t("member.monitoring.analytics.channels.#{key}", default: value.to_s)
  end
end
