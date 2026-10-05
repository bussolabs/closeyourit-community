# frozen_string_literal: true

module Monitoring
  # I REGISTRI cross-app: come si intitola una riga, quante ne stiamo guardando e il grafico del
  # volume. Il livello è lo stesso vocabolario degli errori, quindi la palette è quella (CYRA-742).
  module LogsHelper
    # I log condividono i livelli con gli errori (vocabolario SDK) → stessa palette.
    def log_level_color(level) = error_level_color(level)

    # CYRA-577 — Come si intitola un registro. Il titolo era il messaggio INTERO: su un'eccezione Rails
    # sono quasi tremila caratteri col backtrace dentro, un titolo alto più di una schermata che spingeva
    # livello, progetto e momento sotto la piega. Qui si prende la PRIMA RIGA e la si taglia; il testo
    # completo vive nel blocco tecnico della pagina, dove si legge riga per riga e scorre da solo.
    #
    # Due potature, entrambe su ciò che il messaggio di Rails ha davvero in testa:
    #   - la riga vuota che DebugExceptions mette prima dell'eccezione (stesso caso di CYRA-559): si
    #     salta, altrimenti il titolo sarebbe vuoto;
    #   - il prefisso «[<id richiesta>]», riconosciuto con la STESSA regola dell'ingest (fonte unica):
    #     trentasei caratteri di codice consumavano il titolo intero e tutta la briciola di pane, e
    #     quel codice si legge già per esteso nel riquadro della richiesta.
    # Se dopo la potatura non resta niente (messaggio fatto del solo tag) si tiene la riga com'è: meglio
    # un codice che un titolo vuoto.
    LOG_HEADLINE_MAX = 120

    def log_entry_headline(entry, limit: LOG_HEADLINE_MAX)
      row = entry.message.to_s.each_line.lazy.map(&:strip).find(&:present?).to_s
      trimmed = row.sub(::Logs::Ingest::Normalize::TRACE_FROM_TAG, "").strip

      (trimmed.presence || row).truncate(limit, separator: " ", omission: "…")
    end

    # CYRA-354 — il conteggio filtrato col totale accanto: «36 di 55.148». Quando non c'è nessun filtro
    # i due numeri coincidono e il «di ...» sparisce, perché non direbbe niente.
    def log_count_label(filtered, total)
      return number_with_delimiter(total.to_i) if filtered.nil? || filtered.to_i == total.to_i

      t("member.monitoring.logs.count_of",
        filtered: number_with_delimiter(filtered.to_i), total: number_with_delimiter(total.to_i))
    end

    # The hover text of a "filtered of total" count; nil when there is a single number.
    def log_count_title(filtered, total)
      t("member.monitoring.logs.count_of_title") unless filtered.nil? || filtered.to_i == total.to_i
    end

    # Blocchi del grafico del volume: altezza proporzionale al picco, colore acceso dove ci sono voci
    # allarmanti — è la distinzione che si guarda per prima. Cliccare un blocco restringe l'elenco a
    # quella finestra (stesso meccanismo del grafico delle prestazioni, CYRA-46).
    def log_volume_bars(buckets, max, href_for:)
      Array(buckets).map do |bucket|
        empty = bucket.count.zero?
        {
          height: empty ? 6 : [ ((bucket.count.to_f / [ max, 1 ].max) * 100).round, 4 ].max,
          color_class: log_volume_bar_class(bucket, empty),
          empty: empty,
          href: empty ? nil : href_for.call(bucket),
          time_label: l(bucket.from, format: :short),
          value_line: t("member.monitoring.logs.chart_bucket", count: bucket.count, alarming: bucket.alarming),
          aria_label: t("member.monitoring.logs.chart_bucket_aria",
                        time: l(bucket.from, format: :short), count: bucket.count)
        }
      end
    end

    def log_volume_bar_class(bucket, empty)
      return "bg-stone-100 dark:bg-zinc-800" if empty
      return "bg-rose-400" if bucket.alarming.positive?

      "bg-indigo-300"
    end
  end
end
