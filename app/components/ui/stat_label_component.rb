# frozen_string_literal: true

module Ui
  # Design-system count, written as inline text (DESIGN.md T12), never a pill: the Mono number,
  # colored by state, then the grey word ("12 to do"); a dot sits between neighbouring counts. A value
  # that is not a number (dates, names, "—") keeps its label in front ("Last check: 2 hours ago").
  # Color classes are LITERAL (the Tailwind scanner purges interpolated ones).
  #
  # `value_color` is a code variant: a value outside the map (nil included) falls back to neutral
  # (a page must not crash over a color), consistent with BadgeComponent.
  #
  # CYRA-383 — with `href` the count becomes an underlined LINK: status counts on top of a list ask
  # "show me only these", and opening the filters panel for something already written there is
  # wasted work. `active` marks it as a filter that is on.
  class StatLabelComponent < BaseComponent
    # The dot before every count but the first keeps a row of counts one line of text (T12).
    BASE = "inline-flex items-baseline gap-1 text-[12px] text-gray-500 dark:text-zinc-400 whitespace-nowrap " \
           "not-first:before:mr-0.5 not-first:before:text-stone-300 dark:not-first:before:text-zinc-600 not-first:before:content-['·']"

    VALUE_COLORS = {
      neutral: "text-zinc-900 dark:text-zinc-100",
      gray:    "text-gray-500 dark:text-zinc-400",
      amber:   "text-amber-600 dark:text-amber-400",
      orange:  "text-orange-600 dark:text-orange-400",
      indigo:  "text-indigo-600 dark:text-indigo-400",
      violet:  "text-violet-600 dark:text-violet-400",
      sky:     "text-sky-600 dark:text-sky-400",
      emerald: "text-emerald-600 dark:text-emerald-400",
      teal:    "text-teal-600 dark:text-teal-400",
      # CYRA-685 — alias: stesso significato, stessa tinta (l'audit contava due tinte per «negativo»).
      rose:    "text-red-600 dark:text-red-400",
      red:     "text-red-600 dark:text-red-400"
    }.freeze

    DEFAULT_VALUE_COLOR = :neutral

    LINK = "underline decoration-dotted decoration-stone-300 dark:decoration-zinc-600 underline-offset-4 hover:text-zinc-900 dark:hover:text-zinc-100 " \
           "focus:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500/40 dark:focus-visible:ring-indigo-400/40 rounded-sm"
    ACTIVE = "text-zinc-900 dark:text-zinc-100 decoration-solid decoration-indigo-500 dark:decoration-indigo-400"

    # CYRA-500 — `trend` è la variazione rispetto al periodo precedente ({ label:, color: }): un
    # numero senza confronto risponde a «quanto», non a «come va». nil = nessun confronto possibile,
    # e allora non si mostra niente: un delta inventato è peggio di nessun delta.
    def initialize(label:, value:, value_color: DEFAULT_VALUE_COLOR, href: nil, active: false,
                   trend: nil, test_id: nil, **options)
      @label = label
      @value = value
      @trend = trend
      @href = href
      @active = active
      # CYRA-552 — `&.`: i chiamanti scrivono `value_color: (condizione ? :emerald : nil)` per dire
      # "colora solo se il caso è notevole". Senza il safe navigation il fallback della riga dopo non
      # veniva mai raggiunto e il ramo normale (nil) faceva 500 sull'intera pagina.
      @value_color = value_color&.to_sym
      @value_color = DEFAULT_VALUE_COLOR unless VALUE_COLORS.key?(@value_color)
      @test_id = test_id
      @options = options
    end

    private

    def html_options
      classes = [ BASE, (LINK if @href), (ACTIVE if @active) ].compact.join(" ")
      options = @options
      options = options.merge(aria: { current: "true" }) if @active && @href
      merge_options(base_class: classes, test_id: @test_id, options:)
    end

    def value_klass
      VALUE_COLORS[@value_color]
    end

    # CYRA-568 — un conteggio è un numero e va scritto come lo scrive la lingua («2.841», non
    # «2841»): le chip in testata mostravano la forma senza separatore accanto alla stessa cifra
    # separata altrove nella pagina. Tutto ciò che numero non è (percentuali, nomi, «—») passa
    # intatto: formattarlo lo rovinerebbe.
    def written_value
      @value.is_a?(Numeric) ? number_with_delimiter(@value) : @value
    end

    def numeric?
      @value.is_a?(Numeric)
    end

    # After the number the label reads as a word ("12 da fare"); an acronym stays as written.
    def word_label
      text = @label.to_s
      text.match?(/\A\p{Lu}\p{Ll}/) ? text[0].downcase + text[1..] : text
    end

    # La variazione sta accanto al valore, più piccola e più chiara: è contesto, non il numero.
    def trend_tag
      return if @trend.blank?

      tag.span(@trend[:label], class: "text-[10.5px] #{VALUE_COLORS.fetch(@trend[:color], VALUE_COLORS[:gray])}",
                               data: { test: "#{@test_id}-trend" }.compact)
    end
  end
end
