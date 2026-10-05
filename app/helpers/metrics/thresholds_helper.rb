# frozen_string_literal: true

module Metrics
  # Le SOGLIE che decidono se una durata è veloce, media o lenta — e la frase che le dichiara. Il
  # colore era l'unico giudizio in pagina, ed era un giudizio segreto (CYRA-341): da qui esce anche
  # dove si cambiano quelle soglie, per chi ha il permesso di farlo (CYRA-742).
  module ThresholdsHelper
    # Soglie di durata media (ms) → colore testo: verde sotto `fast` · ambra fino a `slow` · rosso
    # oltre. CYRA-341: le soglie arrivano dal progetto (::Metrics::Thresholds); senza, i valori di sistema.
    DURATION_COLORS = { fast: "text-emerald-600 dark:text-emerald-400", medium: "text-amber-600 dark:text-amber-400", slow: "text-red-600 dark:text-red-400" }.freeze

    def metric_duration_color(ms, thresholds = nil)
      return "text-gray-400 dark:text-zinc-500" if ms.nil?

      DURATION_COLORS.fetch(::Metrics::Group.duration_status(ms, thresholds))
    end

    # Stesso giudizio del colore testo, nella palette delle chip di intestazione (Ui::StatLabelComponent).
    STAT_COLORS = { fast: :emerald, medium: :amber, slow: :red, empty: :gray }.freeze

    def metric_duration_stat_color(ms, thresholds = nil)
      STAT_COLORS.fetch(::Metrics::Group.duration_status(ms, thresholds))
    end

    # CYRA-341 — la riga che si legge passando sopra un valore colorato: quali sono le due soglie che
    # hanno deciso quel colore e dove si cambiano. Il colore era l'unico giudizio in pagina, ed era un
    # giudizio segreto.
    # Soglie assenti (una riga resa fuori dal contesto di un progetto) → valori di sistema: la frase
    # dice comunque il vero, e nessuna vista resta senza spiegazione del colore.
    def metric_threshold_hint(thresholds = nil)
      [ metric_threshold_scale(thresholds), t("member.metrics.threshold_settings_hint") ].join(" ")
    end

    # Solo la scala (senza il rimando alle impostazioni): nel tooltip del dettaglio il rimando è un
    # link cliccabile, non una frase.
    def metric_threshold_scale(thresholds)
      thresholds ||= ::Metrics::Thresholds.system_defaults
      t("member.metrics.threshold_hint",
        fast: metric_duration_label(thresholds[:fast]), slow: metric_duration_label(thresholds[:slow]))
    end

    # Contenuto del tooltip nel dettaglio: la scala e — per chi può modificarla — il link diretto alle
    # impostazioni del progetto. Senza il permesso resta la frase, che dice dove si cambia senza
    # mandare su una pagina vietata.
    def metric_threshold_tooltip(thresholds, project)
      safe_join([ metric_threshold_scale(thresholds), tag.br, metric_threshold_link(project) ])
    end

    # Chi può modificare le soglie ci arriva con un clic; a chi non può resta la frase, che dice dove
    # si cambiano senza mandarlo su una pagina vietata.
    def metric_threshold_link(project)
      return t("member.metrics.threshold_settings_hint") unless can?("projects.edit", scope: project)

      link_to(t("member.metrics.threshold_settings_link"), member_project_settings_path(project),
              class: "text-indigo-600 dark:text-indigo-400 hover:text-indigo-700 dark:hover:text-indigo-300 font-medium")
    end
  end
end
