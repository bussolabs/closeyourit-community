# frozen_string_literal: true

module Ui
  # KPI / metric tile del design system: label + icona in cima, valore grande in font-mono,
  # con caption/delta opzionali sotto. È la card usata nella dashboard (sezione "Signals").
  #
  # Wrapper polimorfico come ButtonComponent:
  #   - `href` presente → <a> cliccabile (block + hover bordo/bg + focus-ring indigo per la
  #     navigazione da tastiera). Le metriche azionabili linkano alla loro index già filtrata.
  #   - `href` assente  → <div> statico (con `tooltip:` → attributo `title` nativo).
  #
  # `value_color`/`delta_color` sono chiavi di VALUE_COLORS: classi text-* LETTERALI (lo scanner
  # Tailwind purga le interpolate). Un valore fuori mappa fa fallback al neutro invece di sollevare
  # — coerente con Badge/StatLabel, una pagina non deve crashare per un colore.
  #
  # caption/delta sono in flow verticale normale (mt-1), renderizzati solo se presenti: aggiungerli
  # non copre né sposta il valore (niente layout shift), estende solo la tile verso il basso.
  class MetricTileComponent < BaseComponent
    STATIC = "rounded-[10px] border border-stone-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 px-[18px] py-[15px]"
    LINK   = "block #{STATIC} transition-colors hover:border-stone-300 dark:hover:border-zinc-700 hover:bg-stone-50 dark:hover:bg-zinc-800 " \
             "focus:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500/40 dark:focus-visible:ring-indigo-400/40"

    VALUE_BASE  = "mt-2 font-mono text-[28px] font-semibold leading-none"
    DELTA_BASE  = "mt-1 font-mono text-[11px]"
    CAPTION     = "mt-1 text-[11px] text-gray-500 dark:text-zinc-400 leading-tight"

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

    def initialize(label:, value:, icon: nil, value_color: DEFAULT_VALUE_COLOR,
                   href: nil, aria_label: nil, tooltip: nil,
                   caption: nil, delta: nil, delta_color: DEFAULT_VALUE_COLOR,
                   value_test_id: nil, test_id: nil, **options)
      @label = label
      @value = value
      @icon = icon
      @value_color = normalize_color(value_color)
      @href = href
      @aria_label = aria_label
      @tooltip = tooltip
      @caption = caption
      @delta = delta
      @delta_color = normalize_color(delta_color)
      @value_test_id = value_test_id
      @test_id = test_id
      @options = options
    end

    private

    def normalize_color(color)
      key = color.respond_to?(:to_sym) ? color.to_sym : nil
      VALUE_COLORS.key?(key) ? key : DEFAULT_VALUE_COLOR
    end

    # Sceglie <a> vs <div> senza duplicare il body della tile.
    def tile_wrapper(&block)
      if @href
        link_to(@href, link_html_options, &block)
      else
        tag.div(**div_html_options, &block)
      end
    end

    def wrapper_options(base_class)
      opts = merge_options(base_class: base_class, test_id: @test_id, options: @options)
      opts[:title] = @tooltip if @tooltip
      opts
    end

    def link_html_options
      opts = wrapper_options(LINK)
      opts[:"aria-label"] = @aria_label if @aria_label
      opts
    end

    def div_html_options
      wrapper_options(STATIC)
    end

    def value_options
      opts = { class: [ VALUE_BASE, VALUE_COLORS[@value_color] ].join(" ") }
      opts[:data] = { test: @value_test_id } if @value_test_id
      opts
    end

    def delta_klass
      [ DELTA_BASE, VALUE_COLORS[@delta_color] ].join(" ")
    end
  end
end
