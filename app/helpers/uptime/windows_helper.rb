# frozen_string_literal: true

module Uptime
  # La FINESTRA osservata e le durate che la raccontano: quanta parte ha davvero dei dati, perché un
  # tratto è vuoto, da quanto dura il guasto in corso. Un «100% · 24h» calcolato su tre ore è una
  # dichiarazione falsa, e qui si dice su cosa è calcolato (CYRA-487, CYRA-742).
  module WindowsHelper
    # CYRA-487 — quanta parte della finestra ha davvero dei dati. Un «100% · 24h» calcolato su tre ore
    # è una dichiarazione falsa: il numero grande resta, ma accanto c'è scritto su cosa è calcolato.
    # nil quando la copertura è piena (niente da dichiarare) o non ci sono blocchi.
    def uptime_coverage(buckets, range)
      blocks = Array(buckets)
      return nil if blocks.empty?

      with_data = blocks.count { |bucket| bucket[:status] != :empty }
      return nil if with_data == blocks.size

      seconds = Uptime::Monitor.bucket_config(range)[:seconds]
      t("member.uptime.window_coverage", covered: uptime_span_label(with_data * seconds), window: range)
    end

    # Durata in forma breve per la copertura: minuti sotto l'ora, ore sotto il giorno, poi giorni.
    def uptime_span_label(seconds)
      return t("member.uptime.window_span.minutes", count: (seconds / 60.0).round) if seconds < 3_600
      return t("member.uptime.window_span.hours", count: (seconds / 3_600.0).round) if seconds < 86_400

      t("member.uptime.window_span.days", count: (seconds / 86_400.0).round)
    end

    # Perché un blocco è vuoto. Per le finestre brevi la conservazione NON c'entra (i ping grezzi si
    # tengono tre giorni, i rollup orari novanta): o la raccolta non era ancora iniziata, o in quel
    # momento non è stato registrato nessun controllo. Dirlo è diverso dal tacere.
    def uptime_empty_reason(monitor, range)
      window_start = Time.current - Uptime::Monitor.range_duration(range)
      return t("member.uptime.window_empty_reason.before_start") if monitor.created_at > window_start

      t("member.uptime.window_empty_reason.no_checks")
    end

    def uptime_time_ago(time)
      return "—" if time.blank?

      t("member.uptime.time_ago", time: time_ago_in_words(time))
    end

    # CYRA-492 — «Giù da 3h 09m»: da quanto dura il guasto in corso (dall'apertura dell'incident), così
    # «da quanto?» si legge nell'elenco senza aprire il monitor.
    def uptime_down_since(started_at, now = Time.current)
      t("member.uptime.down_since", duration: uptime_short_duration(now - started_at))
    end

    # Cella "tempo" dell'elenco (CYRA-492): per un sito GIÙ (stato MOSTRATO down) e con l'inizio del guasto
    # noto racconta la durata in rosso; in ogni altro caso — su, incerto, dato vecchio (mostrato unknown),
    # nessun incident aperto — resta l'ora dell'ultimo controllo, che non promette una durata che non c'è.
    # `down_since` = istante d'inizio del guasto (batch dal controller, o dal broadcast del singolo monitor).
    def uptime_last_cell(monitor, down_since, now = Time.current)
      return uptime_time_ago(monitor.last_checked_at) unless down_since && monitor.display_status(now) == :down

      tag.span(uptime_down_since(down_since, now), class: "text-red-600 dark:text-red-400", data: { test: "monitor-down-since" })
    end

    # Durata compatta a due unità: "45s", "12m 09s", "3h 09m", "2g 04h". Le due unità sono leggibilità —
    # a quella scala l'unità minore non cambia nessuna decisione. Le sigle dall'i18n perché il giorno non
    # è la stessa lettera in ogni lingua (g/d). Lo zero davanti all'unità minore incolonna le durate.
    def uptime_short_duration(seconds)
      total = seconds.round
      return "#{total}#{t('member.uptime.duration_unit.seconds')}" if total < 60
      return uptime_duration_pair(total / 60, :minutes, total % 60, :seconds) if total < 3_600
      return uptime_duration_pair(total / 3_600, :hours, (total % 3_600) / 60, :minutes) if total < 86_400

      uptime_duration_pair(total / 86_400, :days, (total % 86_400) / 3_600, :hours)
    end

    def uptime_duration_pair(major, major_unit, minor, minor_unit)
      format("%d%s %02d%s", major, t("member.uptime.duration_unit.#{major_unit}"),
             minor, t("member.uptime.duration_unit.#{minor_unit}"))
    end
  end
end
