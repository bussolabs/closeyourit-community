# frozen_string_literal: true

module Uptime
  # Se un sito è SU o GIÙ e con che colore lo si dice: lo stato visibile di un monitor, la percentuale
  # di disponibilità, il blocco della timeline e la fase di un guasto raccontato. Le durate e la
  # copertura della finestra stanno in WindowsHelper (CYRA-742).
  module StatusHelper
    STATUS_COLORS = { "up" => :emerald, "down" => :red, "unknown" => :gray }.freeze

    # Stato visibile: pausa ha precedenza sulla salute (un monitor pausato non si pinga). Oltre la pausa si
    # usa lo stato VISUALIZZATO (display_status): `unknown` quando il dato è vecchio perché il worker dei
    # controlli è fermo (CYRA-209), altrimenti l'ultimo up/down osservato — mai un verde ingannevole.
    def uptime_status_label(monitor)
      return "Paused" if monitor.paused?

      monitor.display_status.to_s.capitalize
    end

    def uptime_status_color(monitor)
      return :gray if monitor.paused?

      STATUS_COLORS.fetch(monitor.display_status.to_s, :gray)
    end

    # Colore del numero di uptime %: verde alto, ambra intermedio, rosso basso. nil → grigio.
    def uptime_percent_color(percent)
      return "text-gray-400 dark:text-zinc-500" if percent.nil?
      return "text-emerald-700 dark:text-emerald-300" if percent >= 99.5
      return "text-amber-700 dark:text-amber-300" if percent >= 98.0

      "text-red-600 dark:text-red-400"
    end

    def uptime_percent_text(percent)
      return "—" if percent.nil?

      number_to_percentage(percent, precision: 4, significant: true, strip_insignificant_zeros: true)
    end

    # Colore semantico dell'uptime % come simbolo per Ui::StatLabelComponent (value_color): verde
    # alto, ambra intermedio, rosso basso, grigio se assente. Gemello di uptime_percent_color, che
    # ritorna invece classi Tailwind dirette per i testi liberi.
    def uptime_percent_symbol(percent)
      return :gray if percent.nil?
      return :emerald if percent >= 99.5
      return :amber if percent >= 98.0

      :red
    end

    # Colore del blocco aggregato della timeline: vuoto→grigio, up→verde, partial→ambra, down→rosso.
    BUCKET_CLASSES = {
      up: "bg-emerald-300", partial: "bg-amber-300", down: "bg-red-400", empty: "bg-stone-200/80 dark:bg-zinc-700/80"
    }.freeze
    def uptime_bucket_class(status) = BUCKET_CLASSES.fetch(status, BUCKET_CLASSES[:empty])

    # Tooltip del blocco: stato + check + ms medio (o "no data").
    def uptime_bucket_title(bucket)
      return t("member.uptime.bucket.no_data") if bucket[:status] == :empty

      parts = [ t("member.uptime.bucket.#{bucket[:status]}"), "#{bucket[:up]}/#{bucket[:total]} up" ]
      parts << "#{bucket[:avg_ms]}ms" if bucket[:avg_ms]
      parts.join(" · ")
    end

    # CYRA-492 — i contatori up/giù dell'header sono link ai filtri dell'elenco: `active` accende il chip
    # quando quel filtro di stato è l'unico in vigore (parità esatta), così riflette lo stato della lista.
    def uptime_status_chip_active?(status)
      Array(params[:status]).reject(&:blank?).map(&:to_s) == [ status.to_s ]
    end

    # Step (phase) di un incident narrato → colore badge (palette Tailwind nativa) e icona FontAwesome.
    PHASE_COLORS = {
      "detected" => :amber, "investigating" => :orange, "fixing" => :violet,
      "monitoring" => :sky, "resolved" => :emerald
    }.freeze
    PHASE_ICONS = {
      "detected" => "triangle-alert", "investigating" => "search",
      "fixing" => "wrench", "monitoring" => "eye", "resolved" => "circle-check"
    }.freeze

    def uptime_phase_color(phase) = PHASE_COLORS.fetch(phase.to_s, :gray)
    def uptime_phase_icon(phase) = PHASE_ICONS.fetch(phase.to_s, "circle")
    def uptime_phase_label(phase) = t("member.uptime.incident.phases.#{phase}")
  end
end
