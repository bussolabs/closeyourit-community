# frozen_string_literal: true

module Servers
  # I testi brevi di una pagina server: gradi, carico, tempo di accensione, "tre minuti fa", la cella
  # che si accende sopra la soglia e il corpo del ticket precompilato. Formattazione soltanto: chi
  # decide COSA vale un numero sta nelle altre parti (CYRA-742).
  module FormatHelper
    # CYRA-460 — il corpo del ticket precompilato dalla pagina di una macchina: nome, indirizzo e i
    # valori di ADESSO. Niente righe di journal: filtrarle da credenziali e dati sensibili richiede uno
    # scrubber dedicato, e un prefill che si porta dietro un segreto è peggio del copia-incolla a mano.
    def server_ticket_description(host)
      [
        t("member.servers.show.ticket_intro", host: host.name),
        "#{t('member.servers.col_cpu')}: #{server_pct_text(host.cpu_pct)}",
        "#{t('member.servers.col_mem')}: #{server_pct_text(host.mem_pct)}",
        "#{t('member.servers.col_disk')}: #{server_pct_text(host.disk_pct)}"
      ].join("\n")
    end

    # CYRA-456 — la CELLA, non il solo numero: in una tabella di diciassette righe un testo colorato
    # non si vede, un fondo sì. Sopra la soglia d'allarme della macchina (o, senza soglia, oltre il
    # limite critico generale) la cella si accende; sotto resta bianca come le altre.
    def server_cell_class(pct, limit)
      return "" if pct.nil?

      ceiling = limit&.to_f
      return "bg-rose-50 dark:bg-rose-500/15" if ceiling&.positive? && pct >= ceiling
      return "bg-rose-50 dark:bg-rose-500/15" if ceiling.nil? && pct >= MeasuresHelper::PCT_CRIT
      return "bg-amber-50 dark:bg-amber-500/15" if ceiling&.positive? && pct >= ceiling * 0.9

      ""
    end

    # Limite d'allarme come percentuale compatta ("80%"), o nil se per quella metrica non c'è una soglia da
    # affiancare al valore (né per-macchina né di regola org) — CYRA-458. Stesso formatting di server_pct_text.
    def server_threshold_pct(value) = value.nil? ? nil : "#{format('%.4g', value)}%"

    # Evento server a soglia → metrica di occupazione (cpu/mem/disco), inverso di ServerThresholds::METRICS.
    METRIC_BY_EVENT = { "server_cpu" => :cpu, "server_mem" => :mem, "server_disk" => :disk }.freeze

    # Soglia (%) da mostrare accanto a una regola server nel pannello del dettaglio host (CYRA-458): la
    # soglia EFFETTIVA per la macchina (override per-macchina || regola org) per le metriche di occupazione
    # cpu/mem/disco. Gli altri eventi a soglia (temperatura in °C, connessioni, lag in s) hanno unità diverse
    # e restano fuori dal riferimento percentuale → nil.
    def server_rule_threshold(rule, thresholds)
      metric = METRIC_BY_EVENT[rule.event_type.to_s]
      metric && thresholds[metric]
    end

    def server_temp_text(temp) = temp.nil? ? "—" : "#{format('%.3g', temp)}°"

    def server_load_text(host)
      return "—" if host.load_1.nil?

      format("%.2f %.2f %.2f", host.load_1, host.load_5, host.load_15)
    end

    def server_uptime_text(seconds)
      return "—" if seconds.to_i.zero?

      days = seconds / 86_400
      return t("member.servers.uptime_days", days: days) if days >= 1

      "#{seconds / 3600}h"
    end

    def server_time_ago(time)
      return "—" if time.blank?

      t("member.servers.time_ago", time: time_ago_in_words(time))
    end
  end
end
