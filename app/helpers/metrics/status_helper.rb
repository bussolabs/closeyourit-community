# frozen_string_literal: true

module Metrics
  # COME SI CHIAMA quello che stiamo guardando: la categoria (query lenta, metodo lento, problema di
  # prestazioni), il tipo di problema del verdetto, lo stato di triage, la firma leggibile e da quanto
  # tempo non succede. Colori, etichette e nomi: le misure stanno in DurationsHelper (CYRA-742).
  module StatusHelper
    KIND_COLORS = { "slow_query" => :sky, "slow_method" => :violet }.freeze

    # CYRA-45: stato di triage → colore BadgeComponent, stessa semantica degli errori
    # (Monitoring::ErrorsHelper::STATUS_COLORS): unresolved ambra · resolved verde · ignored grigio.
    STATUS_COLORS = { "unresolved" => :amber, "resolved" => :emerald, "ignored" => :gray }.freeze

    def metric_kind_color(kind) = KIND_COLORS.fetch(kind.to_s, :gray)
    def metric_status_color(status) = STATUS_COLORS.fetch(status.to_s, :gray)

    # CYRA-342: label leggibile e localizzata del kind (la CATEGORIA: query lenta / metodo lento /
    # problema di performance). Disambigua la dimensione «Categoria» dal «Tipo di problema» (subtype) e
    # compone la gerarchia della card dettaglio. Kind fuori vocabolario → stringa grezza (nessun crash).
    def metric_kind_label(kind) = t("member.metrics.kind.#{kind}", default: kind.to_s)

    # CYRA-343: riga di spiegazione «in parole semplici» della categoria, resa sotto la voce nei filtri.
    # Kind fuori vocabolario → "" (nessuna riga, nessun crash).
    def metric_kind_hint(kind) = t("member.metrics.kind_hint.#{kind}", default: "")

    def metric_time_ago(time)
      return "—" if time.blank?

      t("member.metrics.time_ago", time: time_ago_in_words(time))
    end

    SUBTYPE_COLORS = {
      "n_plus_one" => :rose, "high_query_count" => :amber,
      "slow_request" => :indigo, "slow_external_http" => :cyan,
      "repeated_http" => :teal, "jank" => :fuchsia, "rebuild_storm" => :orange
    }.freeze
    def perf_subtype_color(subtype) = SUBTYPE_COLORS.fetch(subtype.to_s, :gray)
    def perf_subtype_label(subtype) = t("member.metrics.subtype.#{subtype}", default: subtype.to_s)

    # CYRA-343: riga di spiegazione «in parole semplici» del tipo di problema, resa sotto la voce nei
    # filtri. Subtype fuori vocabolario → "" (nessuna riga).
    def perf_subtype_hint(subtype) = t("member.metrics.subtype_hint.#{subtype}", default: "")

    # CYRA-343: la signature LEGGIBILE per la vista. Nei verdetti performance_issue il `title`
    # serializzato inizia col subtype grezzo (es. "n_plus_one SELECT …",
    # "high_query_count Api::V1::MapController#markers"): quel prefisso tecnico è già reso come badge
    # localizzato a parte (perf_subtype_label), quindi va tolto dalla RESA a video. Il valore
    # serializzato (usato nei parametri URL e nell'ingest) resta intatto: si tocca solo la stringa
    # mostrata. Title uguale al solo subtype (caso limite) → l'etichetta leggibile, mai il grezzo.
    def metric_display_signature(group)
      title = group.title.to_s
      return title unless group.kind_performance_issue? && group.subtype.present?

      stripped = title.delete_prefix(group.subtype.to_s).strip
      stripped.presence || perf_subtype_label(group.subtype)
    end
  end
end
