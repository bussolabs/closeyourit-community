# frozen_string_literal: true

module Ui
  # CYRA-363 — lo stato vuoto è l'unico momento in cui il prodotto può insegnare sé stesso, ed era
  # il momento in cui taceva: «Nessuna action», «Ancora nessun case» — una parola mai spiegata — e
  # chi arrivava non sapeva cosa mettere lì né perché.
  #
  # LO SCHEMA, in quattro parti, obbligate dal componente e non dalla buona volontà di chi scrive:
  #   1. `title`   — cosa manca, in una riga;
  #   2. `body`    — a cosa serve quello che manca (non «non c'è niente», ma «serve a…»);
  #   3. `example` — un esempio concreto, che è ciò che rende la spiegazione afferrabile;
  #   4. `action`  — il pulsante per farlo adesso (facoltativo: senza permesso non si mostra).
  #
  # Il modello è l'empty state degli obiettivi di rilascio, l'unico che già insegnava. Qui diventa
  # la forma di tutti: scrivere la solita frase secca richiederebbe di aggirare il componente.
  #
  # `compact` per le celle strette (le colonne della board): stessa struttura, meno aria.
  # `framed` draws the dashed page box, so a page-level empty state never writes it by hand.
  class EmptyStateComponent < BaseComponent
    renders_one :action

    # `example:` resta fortemente consigliato; è `nil` solo quando insegnerebbe un'azione a chi non
    # può farla (CYRA-692) o quando un caso concreto non esiste (CYRA-686, adozione diffusa).
    def initialize(title:, body:, example: nil, icon: "inbox", compact: false, framed: false,
                   test_id: nil, **options)
      @title = title
      @body = body
      @example = example
      @icon = icon
      @compact = compact
      @framed = framed
      @test_id = test_id
      @options = options
    end

    private

    attr_reader :title, :body, :example, :icon, :compact

    def wrapper_options
      opts = merge_options(base_class: "flex flex-col items-center justify-center text-center #{padding}#{frame}",
                           test_id: @test_id, options: @options)
      # DESIGN.md E24 — a page-level empty state fills the page down to the frame (ui--panel-edges).
      opts[:data] = (opts[:data] || {}).merge(empty_fill: true) unless compact
      opts
    end

    def frame = @framed ? " rounded-lg border border-dashed border-stone-300 dark:border-zinc-700 bg-white dark:bg-zinc-900" : ""
    def padding = compact ? "px-4 py-8" : "px-6 py-16"
    def icon_size = compact ? "w-9 h-9 text-[14px]" : "w-12 h-12 text-[18px]"
    def title_size = compact ? "text-[13px]" : "text-[15px]"
    def text_width = compact ? "max-w-[15rem]" : "max-w-sm"
  end
end
