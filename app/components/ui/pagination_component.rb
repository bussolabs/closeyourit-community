# frozen_string_literal: true

module Ui
  # Footer di paginazione della card-tabella, costruito da un oggetto `Pagination::Result`.
  # Gli URL pagina preservano i filtri correnti (query string) cambiando solo `page`.
  # With a single page it shows only "from–to of total"; with no results it renders nothing (DESIGN.md C12).
  class PaginationComponent < BaseComponent
    # CYRA-924 — T10: what the symbols in the table mean, on the same footer row as the pages.
    renders_one :legend

    NUMBER_CLASS = "inline-flex items-center justify-center h-7 w-7 rounded-md text-[12px] " \
                   "font-medium text-gray-500 dark:text-zinc-400 bg-white dark:bg-zinc-900 border border-stone-200 dark:border-zinc-800 hover:bg-stone-50 dark:hover:bg-zinc-800"
    ARROW_CLASS = "inline-flex items-center justify-center h-7 w-7 rounded-md text-gray-500 dark:text-zinc-400 " \
                  "bg-white dark:bg-zinc-900 border border-stone-200 dark:border-zinc-800 hover:bg-stone-50 dark:hover:bg-zinc-800"
    DISABLED_CLASS = "inline-flex items-center justify-center h-7 w-7 rounded-md text-gray-300 dark:text-zinc-600 " \
                     "bg-white dark:bg-zinc-900 border border-stone-200 dark:border-zinc-800 cursor-not-allowed"

    # CYRA-817 — `page_param`/`per_param`: due elenchi paginati sulla stessa pagina (la coda delle
    # proposte e le accettate da archiviare) si sfogliano ciascuno per conto suo. Col nome fisso
    # `page` i due footer scrivevano lo stesso parametro, e girare pagina in uno riportava l'altro
    # dove non era. Il default resta `page`/`per`: le liste con un elenco solo non cambiano.
    def initialize(pagination:, page_param: :page, per_param: :per, test_id: nil)
      @pagination = pagination
      @page_param = page_param.to_s
      @per_param = per_param.to_s
      @test_id = test_id
    end

    def render? = pagination.total.positive?

    private

    attr_reader :pagination

    def number_class = NUMBER_CLASS
    def arrow_class = ARROW_CLASS
    def disabled_class = DISABLED_CLASS

    # URL della pagina n preservando q + filtri correnti (cambia solo il cursore di QUESTO elenco).
    def page_url(num)
      query = request.query_parameters.merge(@page_param => num)
      "#{request.path}?#{query.to_query}"
    end

    # CYRA-408 — l'indirizzo si porta dietro la scelta e riparte da pagina 1: restare alla 90 dopo
    # aver quadruplicato le righe per pagina mostrerebbe il vuoto. Riparte quella di questo elenco:
    # l'altro sulla stessa pagina resta dov'era.
    def per_url(value)
      query = request.query_parameters.merge(@per_param => value).except(@page_param)
      "#{request.path}?#{query.to_query}"
    end

    def per_options = Pagination::PER_OPTIONS

    def show_leading_gap? = pagination.window.first.to_i > 2
    def show_trailing_gap? = pagination.window.last.to_i < pagination.total_pages - 1
    def show_first? = pagination.window.first.to_i > 1
    def show_last? = pagination.window.last.to_i < pagination.total_pages
  end
end
