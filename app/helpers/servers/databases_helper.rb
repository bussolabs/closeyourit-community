# frozen_string_literal: true

module Servers
  # La CRESCITA di un database: le barre della dimensione nel tempo e la variazione col segno. Qui
  # nessuna soglia è "critica" di per sé — una dimensione che sale non è un guasto — quindi il colore
  # dice solo la direzione (CYRA-742).
  module DatabasesHelper
    # Barre della crescita di un database (Ui::HistogramComponent): altezza ∝ dimensione sul picco del
    # periodo, colore indigo uniforme (qui non ci sono soglie: nessuna dimensione è "critica" di per
    # sé). Blocco senza campioni = traccia grigia con stub 6%, come gli altri chart. Classi LITERAL.
    def server_size_chart_bars(buckets, max, range)
      seconds = ::Servers::Sample.bucket_config(range)[:seconds]
      peak = max.to_i
      Array(buckets).map do |bucket|
        value = bucket[:size_bytes]
        {
          height: value.nil? || peak.zero? ? 6 : [ (value * 100.0 / peak).round, 4 ].max.clamp(0, 100),
          color_class: value.nil? ? "bg-stone-200/80 dark:bg-zinc-700/80" : "bg-indigo-400",
          empty: value.nil?,
          time_label: chart_bucket_window(bucket[:at], seconds, range),
          value_line: value.nil? ? t("member.servers.show.no_data") : server_bytes_text(value)
        }
      end
    end

    # Variazione di dimensione col segno: "+12 MB" / "−4 MB" / "invariato".
    def server_size_change_text(bytes)
      return t("member.databases.show.change_none") if bytes.nil? || bytes.zero?

      "#{bytes.positive? ? '+' : '−'}#{number_to_human_size(bytes.abs)}"
    end

    def server_size_change_color(bytes)
      return :gray if bytes.nil? || bytes.zero?

      bytes.positive? ? :amber : :emerald
    end

    # Classe testo per la variazione in tabella (la colonna della lista non passa da StatLabelComponent):
    # stesse tinte semantiche della show. Classi LITERAL — lo scanner di Tailwind non valuta i ternari.
    def server_size_change_class(bytes)
      case server_size_change_color(bytes)
      when :amber then "text-amber-600 dark:text-amber-400"
      when :emerald then "text-emerald-600 dark:text-emerald-400"
      else "text-gray-500 dark:text-zinc-400"
      end
    end

    # Freccia della direzione accanto al valore: su se cresce, giù se cala, niente se invariato o assente.
    def server_size_change_icon(bytes)
      return nil if bytes.nil? || bytes.zero?

      bytes.positive? ? "arrow-up" : "arrow-down"
    end
  end
end
