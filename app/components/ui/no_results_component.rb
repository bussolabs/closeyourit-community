# frozen_string_literal: true

module Ui
  # CYRA-555 — il gemello di EmptyStateComponent per l'altro caso, quello che le pagine confondevano
  # col primo: l'elenco NON è vuoto, è la ricerca a non aver trovato niente. Sette schermate dicevano
  # «Ancora nessuna idea» con cinquanta idee dichiarate nei chip in alto, «Ancora nessun team» con sei
  # team in casa, «Niente qui» sotto una colonna che ne contava centotrentuno — e da nessuna si poteva
  # togliere il filtro senza svuotare il campo a mano o riscrivere l'indirizzo.
  #
  # LE TRE PARTI, obbligate dal componente e non dalla buona volontà di chi scrive:
  #   1. il titolo cita CIÒ CHE È STATO CERCATO (o dice «con questi filtri» se cercato non c'è);
  #   2. il corpo, facoltativo, dice quanti elementi ci sono DAVVERO — è la frase che smentisce il
  #      «non esiste niente» (nelle colonne strette della bacheca si omette: non c'è spazio);
  #   3. l'uscita, sempre presente: azzerare e tornare all'elenco intero.
  #
  # Lo slot `action` aggiunge le vie d'uscita specifiche della pagina (es. «Chiedi ai ticket»).
  # `compact` per le colonne della bacheca: stessa struttura, meno aria.
  class NoResultsComponent < BaseComponent
    renders_many :actions

    def initialize(reset_href:, query: nil, title: nil, body: nil, icon: "search",
                   compact: false, reset_label: nil, reset_test_id: nil, reset_data: {},
                   test_id: nil, **options)
      @reset_href = reset_href
      @query = query
      @title = title
      @body = body
      @icon = icon
      @compact = compact
      @reset_label = reset_label
      @reset_test_id = reset_test_id
      @reset_data = reset_data
      @test_id = test_id
      @options = options
    end

    private

    attr_reader :query, :icon, :compact, :reset_test_id, :reset_data

    # CYRA-694 — azzerare deve anche far DIMENTICARE i filtri ricordati: senza il marker, il
    # ritorno all'elenco «pulito» verrebbe rediretto sui filtri appena tolti.
    def reset_href
      "#{@reset_href}#{@reset_href.to_s.include?("?") ? "&" : "?"}#{RememberableFilters::MARKER_PARAM}=1"
    end

    # Il titolo è la differenza fra «non ci sono dati» e «i dati non corrispondono»: senza query da
    # citare resta comunque un fatto sui filtri, mai sull'esistenza degli elementi.
    def title
      return @title if @title.present?

      query.present? ? t("ui.no_results.title_query", query: query) : t("ui.no_results.title_filtered")
    end

    def body = @body

    # «Azzera la ricerca» quando c'è qualcosa di scritto nel campo, «Azzera i filtri» quando a
    # nascondere le righe sono stati i menu: il bottone nomina ciò che toglie.
    def reset_label
      return @reset_label if @reset_label.present?

      query.present? ? t("ui.no_results.reset_search") : t("ui.no_results.reset_filters")
    end

    def wrapper_options
      opts = merge_options(base_class: "flex flex-col items-center justify-center text-center #{padding}",
                           test_id: @test_id, options: @options)
      # DESIGN.md E24 — same height rule as the empty state: down to the frame, unless compact.
      opts[:data] = (opts[:data] || {}).merge(empty_fill: true) unless compact
      opts
    end

    def padding = compact ? "px-4 py-8" : "px-6 py-16"
    def icon_size = compact ? "w-9 h-9 text-[14px]" : "w-12 h-12 text-[18px]"
    def title_size = compact ? "text-[12.5px]" : "text-[15px]"
    def text_width = compact ? "max-w-[15rem]" : "max-w-sm"
  end
end
