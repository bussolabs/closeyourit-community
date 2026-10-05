# frozen_string_literal: true

module Ui
  # CYRA-748 — La griglia: colonne che crescono con la larghezza. Le pagine la scrivevano a mano
  # (`grid grid-cols-1 lg:grid-cols-3 gap-6`) e ogni schermata sceglieva i suoi breakpoint.
  #
  # Come per la pila, le classi sono LETTERALI e scritte per esteso nelle mappe: Tailwind legge il
  # sorgente e non vede una classe composta con l'interpolazione, quindi `"grid-cols-#{n}"` uscirebbe
  # dal foglio di stile e la griglia diventerebbe una colonna sola su ogni schermo.
  class GridComponent < BaseComponent
    COLS = {
      1 => "grid-cols-1", 2 => "grid-cols-2", 3 => "grid-cols-3", 4 => "grid-cols-4",
      5 => "grid-cols-5", 6 => "grid-cols-6", 12 => "grid-cols-12"
    }.freeze

    SM_COLS = {
      1 => "sm:grid-cols-1", 2 => "sm:grid-cols-2", 3 => "sm:grid-cols-3", 4 => "sm:grid-cols-4",
      5 => "sm:grid-cols-5", 6 => "sm:grid-cols-6", 12 => "sm:grid-cols-12"
    }.freeze

    MD_COLS = {
      1 => "md:grid-cols-1", 2 => "md:grid-cols-2", 3 => "md:grid-cols-3", 4 => "md:grid-cols-4",
      5 => "md:grid-cols-5", 6 => "md:grid-cols-6", 12 => "md:grid-cols-12"
    }.freeze

    LG_COLS = {
      1 => "lg:grid-cols-1", 2 => "lg:grid-cols-2", 3 => "lg:grid-cols-3", 4 => "lg:grid-cols-4",
      5 => "lg:grid-cols-5", 6 => "lg:grid-cols-6", 12 => "lg:grid-cols-12"
    }.freeze

    XL_COLS = {
      1 => "xl:grid-cols-1", 2 => "xl:grid-cols-2", 3 => "xl:grid-cols-3", 4 => "xl:grid-cols-4",
      5 => "xl:grid-cols-5", 6 => "xl:grid-cols-6", 12 => "xl:grid-cols-12"
    }.freeze

    # L'ordine di questa mappa È l'ordine in cui i breakpoint escono nella classe: una scala si legge
    # da piccolo a grande, non nell'ordine in cui il chiamante ha scritto gli argomenti.
    BREAKPOINT_COLS = { sm: SM_COLS, md: MD_COLS, lg: LG_COLS, xl: XL_COLS }.freeze

    GAPS = {
      0 => "gap-0", 1 => "gap-1", 2 => "gap-2", 3 => "gap-3", 4 => "gap-4", 5 => "gap-5", 6 => "gap-6",
      8 => "gap-8", 1.5 => "gap-1.5", 2.5 => "gap-2.5"
    }.freeze

    GAPS_Y = { 1 => "gap-y-1", 2 => "gap-y-2", 3 => "gap-y-3", 4 => "gap-y-4", 5 => "gap-y-5",
               6 => "gap-y-6", 1.5 => "gap-y-1.5", 2.5 => "gap-y-2.5" }.freeze

    GAPS_X = { 1 => "gap-x-1", 2 => "gap-x-2", 3 => "gap-x-3", 4 => "gap-x-4", 5 => "gap-x-5",
               6 => "gap-x-6", 1.5 => "gap-x-1.5", 2.5 => "gap-x-2.5" }.freeze

    def initialize(cols: 1, sm: nil, md: nil, lg: nil, xl: nil, gap: nil, gap_y: nil, gap_x: nil,
                   tag: :div, test_id: nil, **options)
      @cols = cols
      @breakpoints = { sm:, md:, lg:, xl: }.compact
      @gap = gap
      @gap_y = gap_y
      @gap_x = gap_x
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
      raise ArgumentError, "cols fuori mappa: #{@cols}" unless COLS.key?(@cols)

      @breakpoints.each do |bp, n|
        raise ArgumentError, "#{bp}: colonne fuori mappa: #{n}" unless BREAKPOINT_COLS.fetch(bp).key?(n)
      end
      raise ArgumentError, "gap fuori mappa: #{@gap}" if @gap && !GAPS.key?(@gap)
      raise ArgumentError, "gap_y fuori mappa: #{@gap_y}" if @gap_y && !GAPS_Y.key?(@gap_y)
      raise ArgumentError, "gap_x fuori mappa: #{@gap_x}" if @gap_x && !GAPS_X.key?(@gap_x)
    end

    def base_class
      cols = BREAKPOINT_COLS.filter_map { |bp, mapping| mapping[@breakpoints[bp]] if @breakpoints.key?(bp) }
      gaps = [ GAPS[@gap], GAPS_Y[@gap_y], GAPS_X[@gap_x] ].compact
      ([ "grid", COLS[@cols] ] + cols + gaps).join(" ")
    end

    def html_options
      merge_options(base_class: base_class, test_id: @test_id, options: @options)
    end
  end
end
