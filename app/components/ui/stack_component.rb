# frozen_string_literal: true

module Ui
  # CYRA-748 — La pila: il mattone di impaginazione più semplice del design system. Le pagine grandi
  # ripetevano a mano `space-y-6` e `flex items-center gap-2` centinaia di volte, e ogni ripetizione
  # era un'occasione per scrivere una distanza diversa da quella accanto.
  #
  # Le classi sono LETTERALI e vivono in mappe frozen: lo scanner di Tailwind legge il sorgente e
  # purga le classi costruite per interpolazione, quindi `"gap-#{n}"` uscirebbe dal foglio di stile
  # e la pagina si presenterebbe senza spazi. Un valore fuori mappa è un ArgumentError, come per le
  # varianti di ogni altro componente.
  class StackComponent < BaseComponent
    DIRECTIONS = %i[column row].freeze

    # Le distanze effettivamente in uso nelle pagine. Non è la scala completa di Tailwind: aggiungere
    # un gradino qui è una decisione di design, non un dettaglio del chiamante.
    COLUMN_GAPS = {
      0 => "space-y-0", 1 => "space-y-1", 2 => "space-y-2", 3 => "space-y-3", 4 => "space-y-4",
      5 => "space-y-5", 6 => "space-y-6", 8 => "space-y-8",
      0.5 => "space-y-0.5", 1.5 => "space-y-1.5", 2.5 => "space-y-2.5", 3.5 => "space-y-3.5"
    }.freeze

    ROW_GAPS = {
      0 => "gap-0", 1 => "gap-1", 2 => "gap-2", 3 => "gap-3", 4 => "gap-4", 5 => "gap-5", 6 => "gap-6",
      0.5 => "gap-0.5", 1.5 => "gap-1.5", 2.5 => "gap-2.5", 3.5 => "gap-3.5"
    }.freeze

    ALIGNS = {
      start: "items-start", center: "items-center", end: "items-end",
      baseline: "items-baseline", stretch: "items-stretch"
    }.freeze

    JUSTIFIES = {
      start: "justify-start", center: "justify-center", end: "justify-end",
      between: "justify-between", around: "justify-around"
    }.freeze

    def initialize(direction: :column, gap: 4, align: nil, justify: nil, wrap: false, tag: :div,
                   test_id: nil, **options)
      @direction = direction.to_sym
      raise ArgumentError, "direction sconosciuta: #{direction}" unless DIRECTIONS.include?(@direction)

      @gap = gap
      @align = align&.to_sym
      @justify = justify&.to_sym
      @wrap = wrap
      @tag = tag
      @test_id = test_id
      @options = options
      validate!
    end

    def call
      content_tag(@tag, content, **html_options)
    end

    private

    def validate!
      raise ArgumentError, "gap fuori mappa: #{@gap}" unless gaps.key?(@gap)
      raise ArgumentError, "align sconosciuto: #{@align}" if @align && !ALIGNS.key?(@align)
      raise ArgumentError, "justify sconosciuto: #{@justify}" if @justify && !JUSTIFIES.key?(@justify)
    end

    def gaps
      @direction == :row ? ROW_GAPS : COLUMN_GAPS
    end

    # L'ordine è quello che le pagine hanno già scritto a mano (`flex items-center justify-between
    # gap-3`): il diff di una pagina convertita deve restare leggibile.
    def base_class
      if @direction == :row
        [ "flex", ("flex-wrap" if @wrap), ALIGNS[@align], JUSTIFIES[@justify], gaps[@gap] ].compact.join(" ")
      else
        gaps[@gap]
      end
    end

    def html_options
      merge_options(base_class: base_class, test_id: @test_id, options: @options)
    end
  end
end
