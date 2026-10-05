# frozen_string_literal: true

module Ui
  # Toolbar card-top di una tabella-lista: `form GET` con search (`name="q"`) + filtri a CHIP
  # (Ui::SelectComponent wrappato da FilterComponent: visibile solo se attivo nei params o
  # aggiunto dal menu "Filtri") + slot controls (widget sempre visibili, es. range selector)
  # + conteggio a `ml-auto`. Con JS (Stimulus ui--filter-bar) i filtri si applicano in
  # auto-submit alla chiusura del dropdown / rimozione chip; il bottone Apply resta nel DOM
  # come fallback no-JS (nascosto a runtime). Il form NON include `page` → ogni submit
  # riparte da pagina 1.
  class TableToolbarComponent < BaseComponent
    renders_many :filters, "Ui::TableToolbarComponent::FilterComponent"
    # Widget del form sempre visibili, MAI chip (es. range selector uptime).
    renders_many :controls
    # Ui::SavedViewsComponent, rendered in the View menu after the group-by choices. CYRA-395, CYRA-924
    renders_one :views
    renders_one :trailing

    # CYRA-817 — `search_param`: il nome del campo di ricerca. Due elenchi sulla stessa pagina hanno
    # due ricerche, e col nome fisso `q` la seconda avrebbe scritto sul filtro della prima — che è
    # dichiarato in pagina come «fra le proposte in attesa» e significa un'altra cosa.
    def initialize(url:, query: nil, search_placeholder: nil, count: nil, search_param: :q,
                   apply_label: nil, search_test_id: nil, apply_test_id: nil, test_id: nil, hidden: {},
                   sync_params: [], results_frame: nil, semantic_search: false, semantic_selectable: false,
                   search_submit_label: nil, search_submit_test_id: nil, framed: false, group_by: [],
                   view_sections: [])
      @url = url
      # CYRA-883 — bare (default): on the page ground, sticky while scrolling. `framed`: the header
      # row of a panel, for bars that live inside a titled section.
      @framed = framed
      # C62 — how the list is grouped, as links in the View menu: [{ label:, href:, active:, hint:, test_id: }].
      @group_by = Array(group_by)
      # CYRA-924 — more View menu sections above the group-by: [{ heading:, data:, choices: }]. A choice
      # is a link (`href:`) or a button submitting a preference form elsewhere on the page (`form:`).
      @view_sections = Array(view_sections)
      @query = query
      @search_param = search_param
      @search_placeholder = search_placeholder
      @count = count
      @apply_label = apply_label
      @search_test_id = search_test_id
      @apply_test_id = apply_test_id
      @test_id = test_id
      # Param da preservare nel form GET (es. il range dell'istogramma) come hidden field.
      @hidden = hidden || {}
      # CYRA-817 — param di un'ALTRA lista della stessa pagina da preservare LEGGENDOLI dall'indirizzo
      # al momento dell'invio (ui--url-state), non da com'era la pagina quando è stata disegnata: se
      # quell'altra lista vive in un turbo-frame, la barra qui fuori non viene ridisegnata quando lei
      # cambia pagina, e un valore congelato al primo caricamento la riporterebbe indietro.
      @sync_params = Array(sync_params).map(&:to_s)
      # Ricerca semantica come azione esplicita (pulsante) + risultati in un Turbo Frame in place:
      # quando `results_frame` è presente il form targetta il frame e lo stato di caricamento
      # (spinner + filtri disabilitati) è guidato da ui--filter-bar su turbo:submit-start/end.
      @results_frame = results_frame
      @semantic_search = semantic_search
      # `semantic_selectable`: the mode (by meaning / exact words) is a choice, picked from the icon
      # inside the search field, instead of the fixed hidden semantic=1. CYRA-417, CYRA-902
      @semantic_selectable = semantic_selectable
      @search_submit_label = search_submit_label
      @search_submit_test_id = search_submit_test_id
    end

    private

    # I campi nascosti da rendere, appiattiti in coppie nome→valore. CYRA-579: un filtro multi-valore
    # (es. il `release[]` di una vista salvata) è PIÙ campi con lo stesso nome — un solo campo col
    # valore-array manderebbe la stringa `["v1.2.3"]`, che non corrisponde a niente e svuota la lista
    # in silenzio. I blank cadono: un campo vuoto nell'indirizzo è rumore che si porta dietro da solo.
    def hidden_fields
      @hidden.flat_map do |name, value|
        next [] if value.blank?

        value.is_a?(Array) ? value.compact_blank.map { |v| [ "#{name}[]", v ] } : [ [ name, value ] ]
      end
    end

    # Modalità corrente della ricerca dalla query string (come sort_hidden): "0" esplicito = parole
    # esatte; tutto il resto (assente o "1") = per significato. Un solo punto di verità col controller.
    def current_search_mode = request.query_parameters["semantic"] == "0" ? "0" : "1"

    def mode_picker? = @semantic_search && @semantic_selectable

    SEARCH_MODES = [ { value: "1", key: "semantic", icon: "wand-sparkles" },
                     { value: "0", key: "exact", icon: "quote" } ].freeze

    # The placeholder names the active mode, so the field says how it is going to search. CYRA-902
    def search_modes
      SEARCH_MODES.map do |mode|
        label = t("shared.tables.search_mode.#{mode[:key]}")
        mode.merge(label: label,
                   placeholder: t("shared.tables.search_mode.placeholder", base: @search_placeholder, mode: label.downcase_first))
      end
    end

    def current_mode = search_modes.find { |mode| mode[:value] == current_search_mode }

    def search_field_placeholder = mode_picker? ? current_mode[:placeholder] : @search_placeholder

    def search_field_controllers = [ "ui--search-clear", ("ui--search-mode" if mode_picker?) ].compact.join(" ")

    def filters_menu? = filters.any?

    # C62 — the View menu holds how the list looks (group by) and the saved views. CYRA-924
    def view_menu? = menu_sections.any? || views?

    def menu_sections
      @menu_sections ||= @view_sections + (@group_by.any? ? [ { heading: t("shared.tables.group_by"), choices: @group_by } ] : [])
    end

    VIEW_CHOICE_CLASS = "flex w-full items-center gap-2 px-3 h-8 text-left text-[12.5px] text-zinc-700 dark:text-zinc-300 " \
                        "hover:bg-stone-50 dark:hover:bg-zinc-800 aria-[current=true]:text-indigo-600 dark:aria-[current=true]:text-indigo-400"

    # One View menu choice: a link, or a button that submits a preference form elsewhere on the page
    # (`form:`, a form cannot sit inside this menu's neighbour GET form). The active one carries a check.
    def view_choice(choice)
      options = { data: { test: choice[:test_id], **choice.fetch(:data, {}) },
                  aria: { current: (choice[:active] ? "true" : nil) }, class: VIEW_CHOICE_CLASS }
      body = safe_join([ view_choice_check(choice[:active]), tag.span(choice[:label], class: "truncate"),
                         (tag.span(choice[:hint], class: "ml-auto text-[11.5px] text-gray-400 dark:text-zinc-500") if choice[:hint]) ])
      return tag.button(body, type: "submit", form: choice[:form], **options) if choice[:form]

      link_to(body, choice[:href], **options)
    end

    def view_choice_check(active)
      check = render(Ui::IconComponent.new(name: "check", class: "text-[11px] text-indigo-600 dark:text-indigo-400")) if active
      tag.span(check, class: "w-3.5 shrink-0")
    end

    def view_menu_test_id = @test_id ? "#{@test_id}-view-menu" : "toolbar-view-menu"

    # The View menu is always the rightmost item (C62). Without a count beside it, the menu itself
    # takes the push to the right edge.
    def view_menu_class = "relative order-last#{" ml-auto" unless !trailing? && @count}"

    # Il controller ui--filter-bar serve se ci sono filtri (auto-submit) O se c'è la ricerca
    # semantica (stato di caricamento). Le azioni select-open/close valgono solo coi filtri;
    # le azioni turbo:submit-* (spinner/disable) solo col frame.
    def form_data
      data = @test_id ? { test: @test_id } : {}
      return data unless filters_menu? || @semantic_search

      actions = []
      actions << "ui--select:opened->ui--filter-bar#selectOpened ui--select:closed->ui--filter-bar#selectClosed" if filters.any?
      actions << "turbo:submit-start->ui--filter-bar#start turbo:submit-end->ui--filter-bar#end" if @results_frame
      data.merge(controller: "ui--filter-bar", action: actions.join(" "))
    end

    # Lo stato dell'altra lista com'è NELL'INDIRIZZO al momento del render: il valore di partenza dei
    # campi che ui--url-state riallineerà prima dell'invio. Senza JavaScript restano questi, ed è la
    # risposta giusta — lì ogni navigazione ridisegna la pagina intera.
    def sync_fields
      @sync_params.index_with { |name| request.query_parameters[name] }
    end

    # Data del form_with: target ui--filter-bar (per l'auto-submit dei filtri) + turbo-frame
    # bersaglio (i risultati si aggiornano in place invece di ricaricare la pagina) + il
    # riallineamento all'indirizzo dei param di un'altra lista (CYRA-817).
    def form_html_data
      data = {}
      if @sync_params.any?
        data[:controller] = "ui--url-state"
        data[:action] = "submit->ui--url-state#sync"
      end
      # Il target form serve ogni volta che ui--filter-bar è montato (filtri O ricerca semantica):
      # connect() lo usa per nascondere l'Apply e per requestSubmit.
      data["ui--filter-bar-target"] = "form" if filters_menu? || @semantic_search
      data[:turbo_frame] = @results_frame if @results_frame
      data
    end

    def search_submit_label = @search_submit_label || t("shared.tables.search")

    # Every search field has a visible submit: Enter alone is a gesture nobody sees. CYRA-817, CYRA-902
    def search_submit_test_id = @search_submit_test_id || (@test_id ? "#{@test_id}-search-submit" : "toolbar-search-submit")

    # Param di ordinamento correnti (sort / *_sort, contratto Sortable) da preservare nel
    # submit del form filtri: il form azzera la pagina di proposito ma NON deve perdere
    # l'ordinamento scelto. Auto: nessuna view deve ricordarsi di passarli in `hidden:`.
    # Le chiavi già presenti in `hidden:` vincono (nessun duplicato).
    def sort_hidden
      request.query_parameters.select do |key, value|
        (key == "sort" || key.end_with?("_sort")) && value.present? &&
          !@hidden.key?(key) && !@hidden.key?(key.to_sym)
      end
    end

    # CYRA-694 — il marker dei filtri ricordati: ogni submit della toolbar dichiara «questi sono
    # TUTTI i filtri» (anche nessuno), così svuotare i chip cancella la memoria invece di vedersela
    # riesplodere addosso al ritorno. Reso solo dove ci sono filtri o ricerca: un form senza né
    # l'uno né l'altra non deve sporcare l'indirizzo.
    def remember_marker? = filters.any? || @search_placeholder.present?

    # Il link Azzera è un arrivo col solo marker: filtri dichiarati vuoti → memoria dimenticata.
    def reset_href = "#{@url}#{@url.to_s.include?("?") ? "&" : "?"}#{RememberableFilters::MARKER_PARAM}=1"
    def reset_visible? = @query.present? || filters.any?(&:active?)
    def reset_test_id = @test_id ? "#{@test_id}-reset" : "toolbar-reset"

    def container_class
      layout = @framed ? "px-4 py-3 border-b border-stone-200 dark:border-zinc-800" : "sticky top-0 z-10 py-3 bg-stone-100 dark:bg-zinc-800"
      "flex flex-wrap items-center gap-2 #{layout}"
    end

    def search_hint_test_id = @test_id ? "#{@test_id}-search-hint" : "toolbar-search-hint"
    def search_clear_test_id = @test_id ? "#{@test_id}-search-clear" : "toolbar-search-clear"

    def apply_label = @apply_label || t("shared.tables.apply")
    def apply_test_id = @apply_test_id || (@test_id && "#{@test_id}-apply")
    def filters_menu_test_id = @test_id ? "#{@test_id}-filters-menu" : "toolbar-filters-menu"
  end
end
