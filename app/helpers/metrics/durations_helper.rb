# frozen_string_literal: true

module Metrics
  # Quanto è DURATO: la media del periodo, la variazione rispetto al periodo precedente, i percentili
  # e la forma compatta del tempo cumulato. Solo formattazione e confronto; il giudizio "veloce o
  # lento" lo dà ThresholdsHelper (CYRA-742).
  module DurationsHelper
    # CYRA-341 — la riga che risponde a «sta peggiorando?»: la media del periodo e quanto è cambiata
    # rispetto al periodo precedente della stessa lunghezza (ultime 24 ore contro le 24 prima).
    def metric_duration_summary(trend, range)
      window = t("member.metrics.window.#{range}", default: range.to_s)
      return t("member.metrics.duration_empty", window: window) if trend.blank? || trend[:current_ms].nil?

      media = t("member.metrics.duration_current", current: metric_duration_label(trend[:current_ms]), window: window)
      "#{media} · #{metric_compare_phrase(trend[:delta_pct], range)}"
    end

    # «il 35% in più rispetto alle 24 ore precedenti», oppure il perché il confronto non c'è.
    def metric_compare_phrase(pct, range)
      return t("member.metrics.compare_missing") if pct.nil?

      [ metric_delta_phrase(pct), t("member.metrics.compare.#{range}", default: "") ].reject(&:blank?).join(" ")
    end

    def metric_delta_phrase(pct)
      return t("member.metrics.delta_flat") if pct.zero?

      t("member.metrics.delta_#{pct.positive? ? 'up' : 'down'}", pct: pct.abs)
    end

    # Variazione della durata sul periodo precedente (::Metrics::Group#duration_trend) nella forma che
    # Ui::StatLabelComponent si aspetta. Per una durata più alto è peggio: ▲ rosso, ▼ verde. nil
    # quando il confronto non esiste — mai un delta inventato.
    def metric_trend(trend)
      pct = trend && trend[:delta_pct]
      return nil if pct.nil?

      { label: metric_trend_label(pct), color: metric_trend_color(pct) }
    end

    def metric_trend_label(pct)
      return t("member.metrics.trend_flat") if pct.zero?

      "#{pct.positive? ? '▲' : '▼'} #{pct.abs}%"
    end

    def metric_trend_color(pct)
      return :gray if pct.zero?

      pct.positive? ? :rose : :emerald
    end

    # Sotto il secondo in ms, sopra scalata come il tempo totale: «974203ms» non si legge.
    def metric_duration_label(ms)
      return "—" if ms.nil?
      return metric_total_duration_label(ms) if ms >= 1_000

      "#{ms.round}ms"
    end

    # CYRA-339: durata cumulata (tempo totale speso = media × occorrenze) in forma compatta. La somma
    # vale spesso centinaia di milioni di ms: si scala mostrando UNA unità dominante, senza ".0" superfluo
    # e col punto come separatore (numero indipendente dal locale). L'UNITÀ è localizzata via i18n
    # (member.metrics.duration_unit.*) — es. giorni "g" in it, "d" in en. nil → "—".
    def metric_total_duration_label(ms)
      return "—" if ms.nil?

      ms = ms.to_f
      return "#{ms.round}#{duration_unit(:ms)}" if ms < 1_000

      scaled = lambda do |value, unit|
        rounded = value.round(1)
        "#{rounded == rounded.to_i ? rounded.to_i : rounded}#{duration_unit(unit)}"
      end
      seconds = ms / 1_000.0
      return scaled.call(seconds, :s) if seconds < 60

      minutes = seconds / 60.0
      return scaled.call(minutes, :min) if minutes < 60

      hours = minutes / 60.0
      return scaled.call(hours, :h) if hours < 24

      scaled.call(hours / 24.0, :d)
    end

    def duration_unit(key) = t("member.metrics.duration_unit.#{key}")

    # CYRA-146: etichetta dei percentili di durata (::Metrics::Group#duration_percentiles) come
    # "p50 20ms · p95 29ms · p99 5000ms". `keys` seleziona quali mostrare (tutti nel dettaglio, solo i
    # peggiori nella chip header). "—" se non calcolabili (nessun campione conservato).
    def metric_percentiles_label(percentiles, keys = ::Metrics::Group::PERCENTILES)
      return "—" if percentiles.blank? || keys.all? { |k| percentiles[k].nil? }

      keys.map { |k| "p#{k} #{metric_duration_label(percentiles[k])}" }.join(" · ")
    end
  end
end
