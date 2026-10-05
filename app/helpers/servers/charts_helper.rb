# frozen_string_literal: true

module Servers
  # Le BARRE dei grafici di una macchina: quanto è alto un blocco, di che colore, cosa dice il suo
  # tooltip e come si riassume il grafico per chi lo ascolta invece di guardarlo. Il view-model che
  # esce di qui è quello che Ui::HistogramComponent si aspetta (CYRA-742).
  #
  # Le soglie percentuali e il gibibyte si citano per esteso dalla parte che li definisce: una
  # costante NON attraversa l'include quando è un metodo a nominarla nuda, perché lì la cerca dove
  # il metodo è scritto, non dove finisce incluso.
  module ChartsHelper
    # Barra orizzontale compatta (fleet): larghezza ∝ % con colore a soglia. Classi LITERAL.
    def server_bar_class(pct)
      return "bg-stone-200 dark:bg-zinc-700" if pct.nil?
      return "bg-red-400" if pct >= MeasuresHelper::PCT_CRIT
      return "bg-amber-300" if pct >= MeasuresHelper::PCT_WARN

      "bg-emerald-400"
    end

    # Classe del blocco chart per metrica percentuale (istogramma show). Classi LITERAL (no
    # interpolazione Tailwind), stesse soglie della fleet.
    def server_bucket_class(value)
      return "bg-stone-200/80 dark:bg-zinc-700/80" if value.nil?
      return "bg-red-400" if value >= MeasuresHelper::PCT_CRIT
      return "bg-amber-300" if value >= MeasuresHelper::PCT_WARN

      "bg-emerald-400"
    end

    # Altezza % della barra dell'istogramma (∝ valore, minimo visibile 4%).
    def server_bucket_height(value)
      return 0 if value.nil?

      [ value.round, 4 ].max.clamp(0, 100)
    end

    # Blocco chart temperatura: soglie in °C (80 critico, 60 caldo). Classi LITERAL.
    def server_temp_bucket_class(temp)
      return "bg-stone-200/80 dark:bg-zinc-700/80" if temp.nil?
      return "bg-red-400" if temp >= 80
      return "bg-amber-300" if temp >= 60

      "bg-emerald-300"
    end

    # View-model delle barre di UNA metrica (cpu/mem/disk/temp) per Ui::HistogramComponent — specchio di
    # metric_chart_bars (Metrics::ChartsHelper): mappa i bucket a { height, color_class, unsampled, time_label,
    # value_line }. cpu/mem/disk sono già percentuali su fondo scala 100 (soglie server_bucket_class);
    # temp è in °C e scala sul picco del periodo. time_label = finestra oraria via chart_bucket_window
    # (Monitoring::ChartsHelper), riusa i seconds del range da Servers::Sample.
    # `unsampled` = il blocco non ha campioni (count 0): il componente lo rende con fascia tratteggiata a
    # piena altezza invece della barra minima, così un intervallo "non misurato" non si legge come attività
    # ≈ 0 (CYRA-457). Un valore ZERO misurato (count > 0) resta una barra colorata, non tratteggiata.
    # `total_bytes` (memoria/disco, quando è noto) porta l'assoluto nel tooltip accanto alla percentuale.
    def server_chart_bars(buckets, metric, range, total_bytes: nil)
      metric = metric.to_sym
      scale = server_metric_scale(buckets, metric)
      seconds = ::Servers::Sample.bucket_config(range)[:seconds]
      Array(buckets).map do |bucket|
        value = server_metric_value(bucket, metric)
        {
          height: server_chart_height(value, metric, scale: scale),
          color_class: server_metric_bucket_class(value, metric),
          unsampled: bucket[:count].to_i.zero?,
          time_label: chart_bucket_window(bucket[:at], seconds, range),
          value_line: value.nil? ? t("member.servers.show.no_data") : server_metric_text(
            value, metric, total_bytes: total_bytes, used_bytes: server_bucket_used_bytes(bucket, metric)
          )
        }
      end
    end

    # Byte occupati misurati nel blocco (memoria/disco), quando il campione porta il dettaglio.
    # Per cpu e temperatura la chiave non esiste: nil, e il tooltip resta sulla sola metrica.
    def server_bucket_used_bytes(bucket, metric)
      used_gb = bucket[:"#{metric}_gb"]
      return nil if used_gb.nil?

      (used_gb * FilesystemsHelper::GIBIBYTE).round
    end

    # Altezza della barra. Le percentuali stanno su fondo scala fisso 100 — una CPU al 12% deve
    # leggersi bassa, non piena — mentre le altre famiglie scalano sul picco del periodo. Valore
    # assente → stub 6% (sui blocchi `unsampled` il componente disegna comunque il tratteggio a piena
    # altezza e questa altezza non viene usata).
    def server_chart_height(value, metric, scale: nil)
      return 6 if value.nil?
      return server_bucket_height(value) if server_metric_kind(metric) == :pct
      return 0 if scale.nil? || scale <= 0

      [ (value * 100.0 / scale).round, 4 ].max.clamp(0, 100)
    end

    # Riassunto sr-only del grafico. Il gutter con l'asse Y è aria-hidden (è decorazione visiva), quindi
    # la scala va detta qui: chi legge con lo screen reader deve sapere su quale fondo scala stanno le
    # barre. Senza un massimo dichiarabile (temperatura senza sensori) si degrada alla forma base.
    def server_chart_summary(label, range, metric:, total_bytes: nil, buckets: nil)
      kind = server_metric_kind(metric)
      scale = server_metric_scale(buckets, metric)
      max = case kind
      when :temp then scale&.then { |s| "#{s}°" }
      when :watt then scale&.then { |s| "#{format('%.3g', s)} W" }
      when :bytes then scale&.then { |s| server_bytes_text(s) }
      else total_bytes ? server_bytes_text(total_bytes) : "100%"
      end
      return t("member.servers.show.chart_summary", metric: label, range: range) if max.nil?

      t("member.servers.show.chart_summary_scaled", metric: label, range: range, max: max)
    end

    # Istante da cui l'host ha misure ad alta risoluzione nella finestra corrente: `at` del primo blocco
    # con campioni, ma solo se preceduto da blocchi vuoti — c'è un tratto iniziale "non misurato" da
    # dichiarare a parole sotto il titolo del grafico (CYRA-457). Primo blocco già pieno (nessun vuoto
    # iniziale) o nessun blocco con campioni → nil: niente riga.
    def server_hires_since(buckets)
      buckets = Array(buckets)
      first = buckets.index { |bucket| bucket[:count].to_i.positive? }
      return nil if first.nil? || first.zero?

      buckets[first][:at]
    end
  end
end
