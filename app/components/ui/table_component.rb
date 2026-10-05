# frozen_string_literal: true

module Ui
  # Tabella DS: possiede l'overflow + lo shell <table>/<thead>/<tbody>.
  #
  # CYRA-670 — `overflow-x-auto` è il default: era opt-in (`scrollable:`/`menu:`) e 16 tabelle su
  # 75 se l'erano dimenticato, sfondando la pagina su schermo stretto invece di scorrere. Chi
  # ospita in una cella un pannello `absolute` che deve uscire dal riquadro passa `scrollable:
  # false`, perché in CSS un asse non-visible costringe l'altro ad `auto` e il pannello verrebbe
  # clippato. Non è il caso dei row-menu: `Ui::RowMenuComponent` posiziona il dropdown a
  # `position:fixed` (controller `ui--row-menu`), che sfugge all'overflow — per questo il vecchio
  # flag `menu:` non serve più e il componente lo rifiuta.
  #
  # Slot `head` = celle <th> (il componente avvolge in <thead><tr>); il contenuto
  # del blocco = le <tr> (di norma una render collection nella view).
  #
  # CYRA-924 — the pieces a table switches on (DESIGN.md C48–C81): `label:`/`table_data:` go on the
  # <table>, `stacked:` turns rows into cards below 768px with CSS only (C73), `compact:` (C53),
  # `sticky:` first/last column (C59, C75), `grouped:` collapsible groups (C57), slots `state`
  # (C51) and `foot`. Rows and cells come from RowComponent, CellComponent and GroupRowComponent.
  class TableComponent < BaseComponent
    STICKY_SIDES = { first: %w[ui-table--sticky-first], last: %w[ui-table--sticky-last],
                     both: %w[ui-table--sticky-first ui-table--sticky-last] }.freeze

    renders_one :head
    renders_one :state, StateComponent
    renders_one :foot

    def initialize(scrollable: true, scroll_y: false, body_id: nil, body_test_id: nil, test_id: nil,
                   label: nil, table_data: {}, stacked: false, compact: false, sticky: nil, grouped: false,
                   selectable: false, **options)
      # `menu:` finirebbe in `options` e uscirebbe come attributo `menu="true"` sul wrapper: meglio
      # fermarsi qui che rendere in silenzio HTML che nessuno ha chiesto.
      raise ArgumentError, "Ui::TableComponent: `menu:` non esiste più, ogni tabella scorre di default" if options.key?(:menu)

      @scrollable = scrollable
      @scroll_y = scroll_y
      @body_id = body_id
      @body_test_id = body_test_id
      @test_id = test_id
      @options = options
      @label = label
      @table_data = table_data
      @stacked = stacked
      @compact = compact
      raise ArgumentError, "Ui::TableComponent: unknown sticky side #{sticky.inspect}" if sticky && !STICKY_SIDES.key?(sticky)

      @sticky = sticky
      @grouped = grouped
      @selectable = selectable
    end

    # How many columns the header declares, so a full-width row (state, group) spans them all. The
    # head slot is rendered once and memoized, so rows can ask while the body is being built.
    def column_count
      return 1 unless head?

      [ head.to_s.scan(/<th[\s>]/).size + (selectable? ? 1 : 0), 1 ].max
    end

    private

    # C56 — `selectable: true` or `{ test_id: }`: the select-all box in front of the headers; each row
    # brings its own box through RowComponent `select:`.
    def selectable? = @selectable.present?

    def select_all_header
      test_id = @selectable.is_a?(Hash) ? @selectable[:test_id] : nil
      tag.th(scope: "col", class: "ui-table-select w-10") do
        tag.input(type: "checkbox", "aria-label": t("shared.bulk_triage.select_all"),
                  class: "h-3.5 w-3.5 rounded border-stone-300 dark:border-zinc-700 text-indigo-600 dark:text-indigo-400 focus:ring-indigo-500 dark:focus:ring-indigo-400",
                  data: { "ui--bulk-select-target": "all", action: "change->ui--bulk-select#toggleAll", test: test_id }.compact)
      end
    end

    def table_options
      classes = [ "ui-table w-full text-left", ("ui-table--stacked" if @stacked), ("ui-table--compact" if @compact),
                  *STICKY_SIDES.fetch(@sticky, []) ].compact.join(" ")
      { class: classes, "aria-label": @label, data: @table_data.presence }.compact
    end

    def grouped? = @grouped

    # <tbody> data-test opzionale: un tbody target di broadcast (body_id) porta
    # spesso anche un data-test semantico → lo passiamo qui, nil = nessun attributo.
    def body_options
      { id: @body_id, class: "divide-y divide-stone-200 dark:divide-zinc-800" }.tap do |opts|
        opts[:data] = { test: @body_test_id } if @body_test_id
      end
    end

    # CYRA-564 — con lo scorrimento verticale l'intestazione resta appiccicata in alto: a metà
    # elenco, colonne di soli numeri senza il proprio nome non si leggono più.
    def head_class
      @scroll_y ? "bg-stone-50 dark:bg-zinc-800 sticky top-0 z-10" : "bg-stone-50 dark:bg-zinc-800"
    end

    def scrollable? = @scrollable

    # CYRA-663 — l'indicatore «scorri» aveva un nome fisso: due tabelle nella stessa pagina
    # rendevano il selettore ambiguo e una prova poteva puntare all'indicatore dell'altra.
    # Quando la tabella ha un nome suo, l'indicatore lo eredita.
    def scroll_hint_test_id
      @test_id ? "#{@test_id}-scroll-hint" : "table-scroll-hint"
    end

    def scroller_options
      html_options.deep_merge(data: { "ui--scroll-hint-target" => "scroller" })
    end

    # CYRA-351 — quando la tabella scorre, il bordo destro lo dice: senza un segno, una tabella
    # tagliata a metà si legge come una tabella con meno colonne, e le colonne fuori campo non le
    # cerca nessuno. L'ombra compare solo se c'è davvero altro da vedere (la decide il controller).
    # CYRA-564 — `scroll_y:` per le tabelle a lunghezza non nota (i container di una macchina): la
    # tabella scorre dentro il proprio riquadro invece di allungare la pagina. Un solo `overflow-auto`
    # e non la combo `overflow-visible` + `overflow-y-auto`: in CSS un asse non-visible costringe
    # l'altro ad `auto` comunque, e scriverlo esplicito evita di dipendere dall'ordine con cui
    # Tailwind emette le due utility. Opt-in: senza il flag l'HTML è identico a prima.
    def html_options
      overflow = if @scroll_y
                   "max-h-[420px] overflow-auto"
      elsif scrollable?
                   "overflow-x-auto"
      else
                   "overflow-visible"
      end
      merge_options(base_class: overflow, test_id: @test_id, options: @options)
    end
  end
end
