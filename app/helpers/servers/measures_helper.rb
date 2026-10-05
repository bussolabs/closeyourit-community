# frozen_string_literal: true

module Servers
  # Che cosa MISURA una metrica e come si legge il suo valore: la famiglia (percentuale, gradi, watt,
  # byte) decide fondo scala, formato e colore. Le barre che ne nascono stanno in ChartsHelper, gli
  # assi in AxesHelper (CYRA-742).
  module MeasuresHelper
    # Soglie cromatiche percentuali (cpu/mem/disk), condivise da testo/barra/istogramma:
    # < 50 verde (idle/ok) · 50–79 ambra (carico, es. 59% = giallo) · ≥ 80 rosso (alto).
    PCT_WARN = 50
    PCT_CRIT = 80

    # Colore del valore percentuale (cpu/mem/disk): verde basso, ambra medio, rosso alto.
    def server_pct_color(pct)
      return "text-gray-400 dark:text-zinc-500" if pct.nil?
      return "text-red-600 dark:text-red-400" if pct >= PCT_CRIT
      return "text-amber-600 dark:text-amber-400" if pct >= PCT_WARN

      "text-emerald-600 dark:text-emerald-400"
    end

    def server_pct_text(pct) = pct.nil? ? "—" : "#{format('%.4g', pct)}%"

    # CYRA-703 — non tutte le metriche del grafico sono percentuali, e la famiglia decide quattro cose
    # insieme: fondo scala, colore della barra, formato del valore e asse Y.
    #   :pct   fondo scala fisso 0–100 (cpu, mem, disk, uso della scheda grafica)
    #   :temp  gradini da 20°, scala sul picco (temperatura)
    #   :watt  scala sul picco, valore in watt (assorbimento della scheda grafica)
    #   :bytes scala sul picco, valore in byte (traffico di rete)
    # Prima la distinzione era un booleano `temp:` passato a cinque helper: con due metriche nuove non
    # percentuali sarebbero diventati tre booleani da tenere allineati a mano.
    METRIC_KINDS = { cpu: :pct, mem: :pct, disk: :pct, gpu: :pct,
                     temp: :temp, gpu_watt: :watt, net: :bytes }.freeze

    # Una metrica sconosciuta ricade sulla percentuale invece di sollevare: è la stessa scelta di
    # BadgeComponent sui colori fuori mappa — una pagina non deve rompersi per una chiave nuova.
    def server_metric_kind(metric) = METRIC_KINDS.fetch(metric.to_sym, :pct)

    # Il valore di UN blocco. Quasi tutte le metriche leggono la propria chiave; il traffico di rete è
    # la somma delle due direzioni, che nei blocchi restano separate (net_out/net_in). Sul blocco senza
    # campioni resta nil: uno zero si leggerebbe come "misurato, e non passava niente".
    def server_metric_value(bucket, metric)
      return bucket[metric.to_sym] unless metric.to_sym == :net
      return nil if bucket[:count].to_i.zero?

      bucket[:net_out].to_i + bucket[:net_in].to_i
    end

    # Picco del periodo, per le famiglie che scalano sul massimo osservato.
    def server_metric_peak(buckets, metric)
      Array(buckets).filter_map { |bucket| server_metric_value(bucket, metric) }.max
    end

    # Fondo scala per famiglia. nil per :pct (fisso a 100) e quando non c'è nulla da scalare.
    def server_metric_scale(buckets, metric)
      kind = server_metric_kind(metric)
      return nil if kind == :pct

      peak = server_metric_peak(buckets, metric)
      return nil if peak.nil? || peak.to_f <= 0

      kind == :temp ? server_temp_scale_max(peak.ceil) : peak.to_f
    end

    # Il valore già formattato, nell'unità della famiglia.
    def server_metric_text(value, metric, total_bytes: nil, used_bytes: nil)
      case server_metric_kind(metric)
      when :temp then server_temp_text(value)
      when :watt then value.nil? ? "—" : "#{format('%.4g', value)} W"
      when :bytes then value.nil? ? "—" : server_bytes_text(value)
      else server_current_text(value, temp: false, total_bytes: total_bytes, used_bytes: used_bytes)
      end
    end

    # Colore della barra. Percentuali e temperatura hanno soglie che vogliono dire qualcosa; watt e
    # byte no — un traffico alto non è un guasto — quindi restano di una tinta sola.
    def server_metric_bucket_class(value, metric)
      case server_metric_kind(metric)
      when :temp then server_temp_bucket_class(value)
      when :pct then server_bucket_class(value)
      else value.nil? ? "bg-stone-200/80 dark:bg-zinc-700/80" : "bg-indigo-400"
      end
    end
  end
end
