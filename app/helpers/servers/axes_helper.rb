# frozen_string_literal: true

module Servers
  # L'asse Y dei grafici di una macchina: quali valori scrivere a sinistra e a che altezza. Una scala
  # per famiglia — percentuali su fondo fisso, gradi a gradini tondi, watt e byte sul picco del
  # periodo — più quella delle dimensioni di un database (CYRA-742).
  module AxesHelper
    # Asse Y per famiglia: fisso 0–100% per le percentuali, gradini da 20° per la temperatura,
    # gradini sul picco (con l'unità in etichetta) per watt e byte.
    def server_chart_gridlines(buckets, metric)
      case server_metric_kind(metric)
      when :pct then server_pct_gridlines
      when :temp then server_temp_gridlines(buckets)
      when :watt then server_unit_gridlines(server_metric_scale(buckets, metric)) { |v| "#{format('%.3g', v)} W" }
      else server_unit_gridlines(server_metric_scale(buckets, metric)) { |v| server_bytes_text(v) }
      end
    end

    # Gridline su una scala qualunque, con l'etichetta prodotta dal blocco. Lo 0 alla base è esplicito
    # come nelle altre due scale: senza, una colonna a metà altezza non dice su cosa insista.
    def server_unit_gridlines(scale)
      return [] if scale.nil? || scale <= 0

      [ { value: "0", pct: 0.0 } ] +
        chart_gridlines(scale).map { |line| line.merge(value: yield(line[:value].to_f)) }
    end

    # Asse Y delle metriche percentuali: fondo scala dichiarato 0 → 100%, uguale per cpu/mem/disk e per
    # ogni server, così due grafici sono confrontabili a colpo d'occhio. Lo 0 alla base rende esplicito
    # il "da–a" (senza, una colonna a metà altezza non dice su quale scala stia).
    def server_pct_gridlines
      [ { value: "0", pct: 0.0 } ] +
        chart_gridlines(100).map { |line| line.merge(value: "#{line[:value]}%") }
    end

    TEMP_SCALE_STEP = 20

    # Asse Y della temperatura: gradini tondi da 20°, non il picco esatto. Due motivi. Le etichette
    # restano leggibili (chart_gridlines su un picco di 61 produce un solo gradino da 50, cioè "50°" e
    # "61°" appiccicate in cima con il resto del grafico vuoto), e la scala non balla: la pagina si
    # ridisegna da sola a ogni push dell'agent, e un asse che cambia ogni minuto è illeggibile.
    def server_temp_gridlines(buckets)
      scale = server_temp_scale_max(server_temp_peak(buckets))
      return [] if scale.nil?

      step = scale > 4 * TEMP_SCALE_STEP ? scale / 4 : TEMP_SCALE_STEP
      (0..scale).step(step).map { |value| { value: value.zero? ? "0" : "#{value}°", pct: value * 100.0 / scale } }
    end

    # Fondo scala: primo multiplo di 20 sopra il picco, con un minimo di 40° perché una CPU non sta
    # sotto. nil se l'host non espone sensori — il caso normale sulle VM cloud, dove il grafico resta
    # vuoto e senza asse inventato.
    def server_temp_scale_max(peak)
      return nil if peak.nil?

      [ (peak.to_f / TEMP_SCALE_STEP).ceil * TEMP_SCALE_STEP, 2 * TEMP_SCALE_STEP ].max
    end

    # Picco di temperatura del periodo (°C, arrotondato per eccesso).
    def server_temp_peak(buckets)
      Array(buckets).filter_map { |bucket| bucket[:temp] }.max&.ceil
    end

    # Etichette dell'asse Y del chart dimensioni. Il gutter è largo 32px: né i byte grezzi né
    # "800 MB" (che manda l'unità a capo) ci stanno — unità a una lettera, come su ogni asse.
    SIZE_UNITS = %w[B K M G T P].freeze

    def server_size_gridlines(max)
      chart_gridlines(max.to_i).map { |line| line.merge(value: server_size_short(line[:value])) }
    end

    def server_size_short(bytes)
      value = bytes.to_f
      unit = 0
      while value >= 1024 && unit < SIZE_UNITS.size - 1
        value /= 1024
        unit += 1
      end
      "#{value < 10 && unit.positive? ? format('%.1f', value) : value.round}#{SIZE_UNITS[unit]}"
    end
  end
end
