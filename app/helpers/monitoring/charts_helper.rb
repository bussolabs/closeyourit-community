# frozen_string_literal: true

module Monitoring
  # Gli ISTOGRAMMI condivisi da errori, metriche e registri: righe di riferimento, etichette del
  # tempo, finestra di un blocco e il view-model di UNA barra — quello che Ui::HistogramComponent si
  # aspetta. Qui non c'è dominio: il colore e la riga valore arrivano già decisi da chi chiama
  # (CYRA-742).
  module ChartsHelper
    # Altezza % della barra dell'istogramma occorrenze: ∝ count rispetto al massimo del range.
    # 0 → 0 (traccia vuota); valori non-zero hanno un minimo visibile (4%).
    def error_bucket_height(count, max)
      return 0 if count.to_i.zero? || max.to_i.zero?

      [ (count * 100.0 / max).round, 4 ].max
    end

    # Righe orizzontali di riferimento: fino a ~3 valori "tondi" (passo 1/2/5×10ⁿ) più la riga di picco.
    # Ritorna [{ value:Int, pct:Float }] con pct = altezza % rispetto al picco. max<2 → nessuna riga.
    def chart_gridlines(max)
      max = max.to_i
      return [] if max < 2

      step = chart_nice_step(max)
      values = (step..max).step(step).to_a
      values << max unless values.include?(max)
      values.uniq.map { |v| { value: v, pct: v * 100.0 / max } }
    end

    # Passo "tondo" (1/2/5×10ⁿ) puntando a ~3 divisioni del picco.
    def chart_nice_step(max)
      rough = max / 3.0
      magnitude = 10.0**Math.log10(rough).floor
      norm = rough / magnitude
      nice = if norm <= 1 then 1 elsif norm <= 2 then 2 elsif norm <= 5 then 5 else 10 end
      (nice * magnitude).round.clamp(1, max)
    end

    # ~4 etichette temporali equispaziate sull'asse X. Ritorna [{ label:String, pct:Float }].
    def chart_xticks(buckets, range)
      buckets = Array(buckets)
      n = buckets.size
      return [] if n < 2

      fmt = chart_time_format(range)
      ticks = 4
      (0...ticks).map { |i| (i * (n - 1) / (ticks - 1.0)).round }.uniq.map do |i|
        at = buckets[i][:at]
        { label: at ? l(at, format: fmt) : "", pct: i * 100.0 / (n - 1) }
      end
    end

    # Formato tempo per range: blocchi brevi (30m/24h) → ora; blocchi lunghi (7d/30d/1y) → giorno.
    # "1y" (bucket settimanali della dashboard analytics) rientra tra i blocchi lunghi.
    def chart_time_format(range)
      # CYRA-500 — su un anno l'asse scriveva «10/08 07/12 05/04 02/08»: un arco che attraversa il
      # capodanno senza dire in che anno si trova ogni tacca.
      return :chart_year if range == "1y"

      %w[7d 30d].include?(range) ? :chart_day : :chart_time
    end

    # Finestra oraria di un blocco per il tooltip: "inizio–fine" (`at` .. `at + seconds`).
    def chart_bucket_window(at, seconds, range)
      return "" if at.blank?

      fmt = chart_time_format(range)
      "#{l(at, format: fmt)}–#{l(at + seconds, format: fmt)}"
    end

    # View-model delle barre per Ui::HistogramComponent (errori): colore indigo uniforme, riga valore
    # = "N occorrenze" pluralizzata; blocchi vuoti = traccia grigia con stub 6%.
    #
    # Drill-down (CYRA-46): con `bucket_href` (lambda `(from, to) -> url`) i blocchi NON vuoti diventano
    # cliccabili → la barra porta from/to del blocco e filtra le occorrenze a quella finestra. Con
    # `active_from`/`active_to` (Time, la finestra filtro dell'URL) si evidenzia il blocco corrente che
    # meglio la rappresenta (quello che ne contiene il punto medio).
    def error_chart_bars(buckets, max, range, bucket_href: nil, active_from: nil, active_to: nil)
      buckets = Array(buckets)
      seconds = ::Errors::Group.bucket_config(range)[:seconds]
      buckets.map do |b|
        empty = b[:count].to_i.zero?
        chart_bar(b, seconds, range, empty:, bucket_href:, active_from:, active_to:,
                  value_line: t("member.monitoring.tooltip_count", count: b[:count].to_i),
                  color_class: empty ? "bg-stone-200 dark:bg-zinc-700" : "bg-indigo-500",
                  height: empty ? 6 : error_bucket_height(b[:count], max))
      end
    end

    # Costruttore comune del view-model di una barra istogramma (errori/metriche): finestra oraria,
    # tooltip, e — per il drill-down CYRA-46 — href del blocco (solo se non vuoto) e flag `active`.
    # `empty` viaggia fino al componente (CYRA-570): se lo sono TUTTI i blocchi, il grafico dichiara
    # il periodo senza dati invece di disegnare una fila di barrette minime.
    def chart_bar(bucket, seconds, range, empty:, value_line:, bucket_href:, active_from:, active_to:, color_class:, height:)
      at = bucket[:at]
      ends_at = at ? at + seconds : nil
      time_label = chart_bucket_window(at, seconds, range)
      {
        height: height,
        color_class: color_class,
        empty: empty,
        time_label: time_label,
        value_line: value_line,
        href: (bucket_href && !empty && at) ? bucket_href.call(at, ends_at) : nil,
        active: chart_bucket_active?(at, ends_at, active_from, active_to),
        aria_label: [ time_label, value_line ].reject(&:blank?).join(" · ")
      }
    end

    # Un blocco è "attivo" (evidenziato) se contiene il PUNTO MEDIO della finestra filtro [from, to).
    # I blocchi sono ricalcolati rispetto a Time.current a ogni request e "scivolano" rispetto al from/to
    # fisso dell'URL (per giunta troncato al secondo): confrontare "at <= from" evidenzierebbe il blocco
    # adiacente (segnalato in review). La finestra vale un blocco, quindi il suo punto medio cade sempre
    # nel blocco corrente che la rappresenta — robusto allo shift + troncatura. Range esclusivo su ends_at.
    def chart_bucket_active?(at, ends_at, active_from, active_to)
      return false if at.blank? || ends_at.blank? || active_from.blank? || active_to.blank? || active_to <= active_from

      mid = active_from + ((active_to - active_from) / 2)
      at <= mid && mid < ends_at
    end
  end
end
