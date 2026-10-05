# frozen_string_literal: true

module Ui
  # Preview del corpo chart occorrenze/metriche. I dati sono finti SOLO qui (eccezione no-mock-data
  # per i cataloghi componenti): in produzione arrivano da error_chart_bars / metric_chart_bars.
  class HistogramComponentPreview < ViewComponent::Preview
    def signed_measurements
      render Ui::HistogramComponent.new(
        bars: [ { height: 50, bottom: 0, color_class: "bg-indigo-500", value_line: "-9" },
          { height: 50, bottom: 50, color_class: "bg-indigo-500", value_line: "9" },
          { height: 0, bottom: 50, color_class: "bg-indigo-500", value_line: "0" },
          { unsampled: true, value_line: "Unknown" } ],
        gridlines: [ { value: "-9", pct: 0 }, { value: "0", pct: 50, baseline: true }, { value: "9", pct: 100 } ]
      )
    end

    # Errori: barre indigo uniformi, picco 10.
    def errors
      counts = [ 6, 4, 3, 5, 2, 4, 7, 10, 4, 6, 6, 6, 6, 5, 6, 3, 5, 8, 8, 6, 6, 9, 9, 5, 10, 10, 6 ]
      render(Ui::HistogramComponent.new(
               bars: bars(counts, max: 10) { |c| { color_class: c.zero? ? "bg-stone-200" : "bg-indigo-500", value_line: "#{c} occorrenze" } },
               gridlines: [ { value: 5, pct: 50.0 }, { value: 10, pct: 100.0 } ],
               xticks: [ { label: "09:00", pct: 0.0 }, { label: "09:10", pct: 34.0 }, { label: "09:20", pct: 66.0 }, { label: "09:29", pct: 100.0 } ],
               buckets_test_id: "error-buckets",
               summary: "Occorrenze nel tempo — picco 10 per blocco nelle ultime 30m."
             ))
    end

    # Drill-down errori: su mobile il plot si allarga quel tanto che basta per mantenere ogni
    # bucket-link a 24px e mostra l'indicazione di scorrimento finché restano blocchi a destra.
    def interactive_errors
      counts = Array.new(56) { |index| index.modulo(9) }
      interactive = bars(counts, max: 8) do |count|
        { color_class: count.zero? ? "bg-stone-200" : "bg-indigo-500",
          value_line: "#{count} occorrenze", href: "#", aria_label: "Blocco con #{count} occorrenze" }
      end
      render(Ui::HistogramComponent.new(
               bars: interactive,
               gridlines: [ { value: 4, pct: 50.0 }, { value: 8, pct: 100.0 } ],
               xticks: [ { label: "7 giorni fa", pct: 0.0 }, { label: "Ora", pct: 100.0 } ],
               buckets_test_id: "interactive-error-buckets",
               summary: "Occorrenze cliccabili negli ultimi sette giorni."
             ))
    end

    # Metriche: colore per performance (verde/ambra/rosso), tooltip con durata media.
    def metrics
      rows = [ [ 3, "bg-emerald-300", "120ms · 3 occ" ], [ 5, "bg-amber-300", "340ms · 5 occ" ],
               [ 8, "bg-red-400", "820ms · 8 occ" ], [ 0, "bg-stone-200/80", "nessun dato" ],
               [ 4, "bg-emerald-300", "90ms · 4 occ" ], [ 6, "bg-amber-300", "410ms · 6 occ" ] ]
      max = rows.map(&:first).max
      bars = rows.map do |count, color, value|
        { height: count.zero? ? 6 : [ (count * 100.0 / max).round, 4 ].max, color_class: color,
          time_label: "09:00–09:30", value_line: value }
      end
      render(Ui::HistogramComponent.new(
               bars: bars,
               gridlines: [ { value: 4, pct: 50.0 }, { value: 8, pct: 100.0 } ],
               xticks: [ { label: "08:30", pct: 0.0 }, { label: "09:00", pct: 50.0 }, { label: "09:30", pct: 100.0 } ],
               buckets_test_id: "duration-buckets",
               summary: "Occorrenze nel tempo — picco 8 per blocco nelle ultime 24h."
             ))
    end

    # Metriche di sistema (CYRA-472): fondo scala fisso 0–100% con lo zero alla base, così una colonna
    # a metà altezza si legge senza indovinare la scala. Le percentuali NON scalano sul picco.
    def system_percentage
      pcts = [ 12, 18, 9, 22, 57, 61, 44, 31, 28, 35, 88, 92, 47, 26, 19, 23, 30, 41, 38, 25 ]
      bars = pcts.map do |pct|
        color = if pct >= 80 then "bg-red-400" elsif pct >= 50 then "bg-amber-300" else "bg-emerald-400" end
        { height: [ pct, 4 ].max, color_class: color, time_label: "09:00–09:30",
          value_line: "#{(32 * pct / 100.0).round(1)} GB · #{pct}%" }
      end
      render(Ui::HistogramComponent.new(
               bars: bars,
               gridlines: [ { value: "0", pct: 0.0 }, { value: "50%", pct: 50.0 }, { value: "100%", pct: 100.0 } ],
               xticks: [ { label: "00:00", pct: 0.0 }, { label: "08:00", pct: 33.0 }, { label: "16:00", pct: 66.0 }, { label: "23:30", pct: 100.0 } ],
               buckets_test_id: "server-mem-buckets",
               summary: "Istogramma Memoria, ultimi 24h, scala da 0 a 32 GB."
             ))
    end

    # Picco basso (nessuna gridline: max < 2) — solo barre e asse.
    def low_peak
      counts = [ 1, 0, 1, 1, 0, 1, 0, 1, 1, 0 ]
      render(Ui::HistogramComponent.new(
               bars: bars(counts, max: 1) { |c| { color_class: c.zero? ? "bg-stone-200" : "bg-indigo-500", value_line: "#{c} occorrenze" } },
               gridlines: [],
               xticks: [ { label: "09:00", pct: 0.0 }, { label: "09:30", pct: 100.0 } ],
               buckets_test_id: "error-buckets",
               summary: "Occorrenze nel tempo — picco 1 per blocco nelle ultime 30m."
             ))
    end

    # Periodo senza misure (CYRA-570): il grafico lo dichiara in una riga invece di disegnare una
    # fila di barrette minime alta un quarto di schermata.
    def empty_period
      empty_bars = Array.new(24) do
        { height: 6, color_class: "bg-stone-200", time_label: "09:00–09:01",
          value_line: "nessuna occorrenza", empty: true }
      end
      render(Ui::HistogramComponent.new(
               bars: empty_bars,
               gridlines: [],
               xticks: [ { label: "09:00", pct: 0.0 }, { label: "09:30", pct: 100.0 } ],
               buckets_test_id: "error-buckets",
               summary: "Occorrenze nel tempo — nessuna occorrenza nelle ultime 30m."
             ))
    end

    private

    def bars(counts, max:)
      counts.map do |c|
        height = c.zero? ? 6 : [ (c * 100.0 / max).round, 4 ].max
        { height: height, time_label: "09:00–09:01" }.merge(yield(c))
      end
    end
  end
end
