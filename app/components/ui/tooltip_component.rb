# frozen_string_literal: true

module Ui
  # Tooltip del design system: un pallino che al passaggio del mouse o al focus da
  # tastiera apre un popup con testo esplicativo. Controller Stimulus ui--tooltip →
  # posizionamento position:fixed calcolato in JS, così il pannello sfugge all'overflow
  # di tabelle e a <dialog> (niente clipping). Le classi placement sono il fallback
  # statico senza JS.
  #
  # Due varianti semantiche via `tone`:
  #   :dark (default) → pallino azzurro, icona "i" bianca. Informazione: "cos'è questa cosa".
  #   :tip            → pallino verde, icona lampadina. Suggerimento/consiglio d'uso.
  #   :muted          → solo icona grigia, senza pallino pieno.
  # L'icona di default segue il tone (info per dark/muted, lightbulb per tip); il caller
  # può forzarla con `icon:`.
  #
  # tone/placement = varianti di CODICE → valore ignoto solleva ArgumentError.
  # text/title = dati già tradotti dalla view (il componente non hardcoda copy).
  class TooltipComponent < BaseComponent
    WRAPPER = "relative inline-flex align-middle"

    # Pallino 12px (w-3 h-3); glifo 8px: leggibile per la "i" e per la lampadina più dettagliata.
    TRIGGER = "inline-flex items-center justify-center w-3 h-3 rounded-full text-[8px] " \
              "leading-none cursor-help transition-colors focus:outline-none " \
              "focus-visible:ring-2 focus-visible:ring-indigo-200 dark:focus-visible:ring-indigo-500/40"

    TONES = {
      dark:  "bg-sky-500 text-white hover:bg-sky-600",
      muted: "text-gray-500 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100",
      tip:   "bg-emerald-100 dark:bg-emerald-500/25 text-emerald-700 dark:text-emerald-300 hover:bg-emerald-200 dark:hover:bg-emerald-500/35"
    }.freeze
    DEFAULT_TONE = :dark

    # Icona Lucide di default per tone: "i" per l'informativo, lampadina per il tip.
    # Il caller può sempre forzare `icon:` esplicito.
    DEFAULT_ICONS = { dark: "info", muted: "info", tip: "lightbulb" }.freeze

    # Reset degli stili ereditabili (le label sono spesso font-mono uppercase tracking):
    # il pannello deve restare leggibile a prescindere dal contesto.
    PANEL = "absolute z-50 w-max max-w-[260px] rounded-md border border-stone-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 " \
            "px-3 py-2 text-[12px] leading-relaxed text-zinc-900 dark:text-zinc-100 text-left font-normal " \
            "normal-case tracking-normal"

    PLACEMENTS = {
      top:    "bottom-full left-1/2 -translate-x-1/2 mb-1.5",
      bottom: "top-full left-1/2 -translate-x-1/2 mt-1.5"
    }.freeze
    DEFAULT_PLACEMENT = :top

    def initialize(text:, title: nil, icon: nil, tone: DEFAULT_TONE,
                   placement: DEFAULT_PLACEMENT, test_id: nil, **options)
      @text = text
      @title = title
      @tone = tone.to_sym
      @placement = placement.to_sym
      @test_id = test_id
      @options = options
      raise ArgumentError, "tone sconosciuto: #{@tone}" unless TONES.key?(@tone)
      raise ArgumentError, "placement sconosciuto: #{@placement}" unless PLACEMENTS.key?(@placement)

      # Icona esplicita del caller, altrimenti il default del tone (info / lightbulb).
      @icon = icon.presence || DEFAULT_ICONS.fetch(@tone)
    end

    private

    def panel_id
      @panel_id ||= "tooltip-#{SecureRandom.hex(4)}"
    end

    def trigger_klass
      [ TRIGGER, TONES.fetch(@tone) ].join(" ")
    end

    def panel_klass
      [ PANEL, PLACEMENTS.fetch(@placement) ].join(" ")
    end

    # Nome accessibile del pallino: il titolo se c'è, altrimenti il testo.
    def aria_label
      @title.presence || @text
    end

    def html_options
      opts = merge_options(base_class: WRAPPER, test_id: @test_id, options: @options)
      opts[:data] = (opts[:data] || {}).merge(
        controller: "ui--tooltip",
        "ui--tooltip-placement-value": @placement
      )
      opts
    end
  end
end
