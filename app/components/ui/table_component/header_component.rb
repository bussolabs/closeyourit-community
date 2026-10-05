# frozen_string_literal: true

module Ui
  class TableComponent < BaseComponent
    # Intestazione <th> di colonna, ordinabile o statica. Con `sort:` rende un link che
    # imposta/inverte il param di ordinamento (`chiave` asc ⇄ `-chiave` desc, contratto di
    # Sortable#current_sort) preservando i filtri correnti e azzerando SOLO la propria
    # pagina; senza `sort:` rende un <th> statico con lo stesso stile — così ogni tabella
    # dichiara tutte le colonne con lo stesso componente. `param:`/`page_param:` permettono
    # più tabelle indipendenti sulla stessa pagina (es. members + inviti).
    class HeaderComponent < BaseComponent
      BASE_CLASS = "font-mono text-[9px] uppercase tracking-[1px] px-4 py-2.5"

      # initial: direzione del PRIMO click su colonna non attiva (:desc naturale per
      # timestamp e contatori, dove "prima i più recenti/grandi" è l'atteso).
      # hint: nota di ordinamento (CYRA-492) — un'icona info col tooltip accanto al label, per
      # dichiarare sull'intestazione un ordine di default che non è quello atteso (es. salute prima
      # dell'alfabetico). nil = nessuna icona; convive col sort (sta fuori dal link, non lo tocca).
      def initialize(label:, sort: nil, initial: :asc, align: :left, classes: nil,
                     param: :sort, page_param: :page, hint: nil, test_id: nil, visible: true,
                     label_hidden: false)
        @label = label
        @label_hidden = label_hidden
        @visible = visible
        @sort = sort&.to_s
        @initial = initial
        @align = align
        @classes = classes
        @param = param.to_s
        @page_param = page_param.to_s
        @hint = hint
        @test_id = test_id
      end

      # CYRA-924 — C76: a column that says nothing in this view is hidden here, not by the page.
      def render? = @visible

      private

      def sortable? = @sort.present?

      # CYRA-670 — `scope: "col"` su ogni intestazione: senza, uno screen reader legge il valore
      # della cella senza mai nominare la colonna a cui appartiene, e su una tabella larga il dato
      # resta senza etichetta.
      # CYRA-924 — C49: label_hidden is the narrow "open" column; padding would only widen an empty cell.
      def th_options
        return { scope: "col", class: @classes }.compact if @label_hidden

        classes = [ BASE_CLASS, (@align == :right ? "text-right" : nil), @classes ].compact.join(" ")
        opts = { scope: "col", class: classes }
        opts[:"aria-sort"] = (direction == :asc ? "ascending" : "descending") if active?
        opts[:data] = { test: @test_id } if @test_id && !sortable?
        opts
      end

      # Stato corrente letto dall'URL (stesso parsing "-" di Sortable#current_sort):
      # nessun accoppiamento col controller, il componente funziona anche nelle tabelle raw.
      def current_raw = request.query_parameters[@param].to_s

      def current_key = current_raw.delete_prefix("-")

      def direction = current_raw.start_with?("-") ? :desc : :asc

      def active? = sortable? && current_key == @sort

      def next_value
        return @initial == :desc ? "-#{@sort}" : @sort unless active?

        direction == :asc ? "-#{@sort}" : @sort
      end

      def toggle_url
        query = request.query_parameters.except(@page_param).merge(@param => next_value)
        "#{request.path}?#{query.to_query}"
      end

      # [Lucide name, color class] of the sort indicator. CYRA-926
      def sort_icon
        return [ "arrow-up-down", "text-gray-300 dark:text-zinc-600" ] unless active?

        direction == :asc ? [ "arrow-up", "text-indigo-600 dark:text-indigo-400" ] : [ "arrow-down", "text-indigo-600 dark:text-indigo-400" ]
      end

      def test_id = @test_id || "sort-#{@sort}"
    end
  end
end
