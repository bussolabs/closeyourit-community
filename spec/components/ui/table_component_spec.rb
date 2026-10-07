# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::TableComponent, type: :component do
  def render_table(**opts)
    render_inline(described_class.new(**opts)) do |t|
      t.with_head { "<th>Nome</th>".html_safe }
      "<tr data-test=\"row\"><td>x</td></tr>".html_safe
    end
  end

  it "rende lo shell tabella con le classi del design system" do
    render_table
    expect(page).to have_css("table.w-full.text-left")
    expect(page).to have_css("thead.bg-stone-50 tr.text-gray-500", text: "Nome")
    expect(page).to have_css("tbody.divide-y.divide-stone-200 tr[data-test='row']")
  end

  # CYRA-670 — l'overflow era opt-in e 16 tabelle su 75 se l'erano dimenticato: su schermo stretto
  # sfondavano la pagina invece di scorrere. Ora scorre chi non dice niente, e chi non deve lo dichiara.
  it "scorre in orizzontale di default" do
    render_table
    expect(page).to have_css("div.overflow-x-auto")
    expect(page).to have_no_css("div.overflow-visible")
  end

  it "con scrollable: false resta overflow-visible (opt-out esplicito)" do
    render_table(scrollable: false)
    expect(page).to have_css("div.overflow-visible")
    expect(page).to have_no_css("div.overflow-x-auto")
  end

  it "prepara un'indicazione visibile soltanto quando il controller rileva altre colonne" do
    render_table(scrollable: true)

    expect(page).to have_css("[data-ui--scroll-hint-target='scroller'].overflow-x-auto")
    # CYRA-663 — lo spazio sotto non e' piu' scritto nel markup: serve solo a non far coprire
    # l'ultima riga dall'indicatore, quindi lo accende il controller quando l'indicatore compare.
    # Sempre acceso lasciava una fascia vuota sotto OGNI tabella su telefono.
    expect(page).not_to have_css("[data-controller='ui--scroll-hint'][class~='max-md:pb-8']")
    expect(page).to have_css("[data-ui--scroll-hint-spazio-class='max-md:pb-8']")
    expect(page).to have_css("[data-ui--scroll-hint-target='horizontal'][data-test='table-scroll-hint'][hidden]",
                             text: I18n.t("shared.scroll_horizontal"), visible: :all)
  end

  it "non aggiunge l'indicazione di scorrimento alle tabelle in opt-out" do
    render_table(scrollable: false)

    expect(page).to have_no_css("[data-test='table-scroll-hint']", visible: :all)
  end

  it "applica body_id al tbody e test_id al wrapper" do
    render_table(body_id: "rows_x", test_id: "my-table")
    expect(page).to have_css("div.overflow-x-auto[data-test='my-table']")
    expect(page).to have_css("tbody#rows_x")
  end

  it "il test_id resta sul wrapper anche in opt-out" do
    render_table(test_id: "my-table", scrollable: false)
    expect(page).to have_css("div.overflow-visible[data-test='my-table']")
  end

  it "applica body_test_id come data-test sul tbody" do
    render_table(body_id: "rows_x", body_test_id: "samples")
    expect(page).to have_css("tbody#rows_x[data-test='samples']")
  end

  it "non emette data-test sul tbody senza body_test_id" do
    render_table(body_id: "rows_x")
    expect(page).to have_no_css("tbody[data-test]")
  end

  # CYRA-564 — una tabella a lunghezza non nota (i container di una macchina) scorre dentro il
  # proprio riquadro invece di allungare la pagina, e l'intestazione resta in vista.
  it "con scroll_y limita l'altezza e tiene l'intestazione appiccicata in alto" do
    render_table(scrollable: true, scroll_y: true)
    expect(page).to have_css("div.overflow-auto.max-h-\\[420px\\]")
    expect(page).to have_css("thead.sticky.top-0")
  end

  it "senza scroll_y l'intestazione non è appiccicata e l'altezza non è limitata" do
    render_table(scrollable: true)
    expect(page).to have_no_css("thead.sticky")
    expect(page).to have_no_css("div[class*='max-h-']")
  end

  # CYRA-670 — `menu:` non esiste più: dal momento che ogni tabella scorre, un flag che
  # accendeva lo scorrimento non distingue nulla. Se una view lo passa ancora finirebbe fra gli
  # attributi HTML del wrapper, quindi il componente lo rifiuta invece di renderlo in silenzio.
  it "rifiuta il vecchio flag menu: invece di emetterlo come attributo HTML" do
    expect { described_class.new(menu: true) }.to raise_error(ArgumentError, /menu/)
  end
  # CYRA-663 — due tabelle nella stessa pagina avevano lo stesso nome sull'indicatore di
  # scorrimento: una prova poteva puntare a quello sbagliato.
  it "l'indicatore di scorrimento prende il nome della tabella, quando ce l'ha" do
    render_inline(described_class.new(test_id: "elenco-ticket")) { "corpo" }
    expect(page).to have_css("[data-test='elenco-ticket-scroll-hint']", visible: :all)
  end

  it "senza un nome proprio resta quello generico" do
    render_inline(described_class.new) { "corpo" }
    expect(page).to have_css("[data-test='table-scroll-hint']", visible: :all)
  end
  # CYRA-924 — the pieces every table switches on from the component (DESIGN.md C48–C81).
  describe "table options" do
    it "puts the label and data on the table itself, not on the wrapper (C74)" do
      render_inline(described_class.new(label: "Occurrences", table_data: { action: "keydown->x#move" })) { "" }
      expect(page).to have_css("table[aria-label='Occurrences'][data-action='keydown->x#move']")
      expect(page).to have_no_css("div[aria-label]")
    end

    it "marks every table with the base class and no modifier by default" do
      render_table
      expect(page).to have_css("table.ui-table")
      expect(page).to have_no_css("table[class*='ui-table--']")
    end

    # C42 — a sticky <thead> sticks to the nearest overflow box, which is the table's own sideways
    # scroller, so it scrolled away with the page. A controller on the table moves it instead.
    it "keeps the header in view while the page scrolls (C42)" do
      render_table
      expect(page).to have_css("table[data-controller='ui--sticky-head']")
    end

    it "keeps a controller passed through table_data next to the sticky header one" do
      render_inline(described_class.new(table_data: { controller: "x" })) do |t|
        t.with_head { "<th>Nome</th>".html_safe }
        ""
      end
      expect(page).to have_css("table[data-controller='ui--sticky-head x']")
    end

    it "leaves the header alone when there is none, or when the table scrolls on its own (scroll_y)" do
      render_inline(described_class.new) { "" }
      expect(page).to have_no_css("table[data-controller]")
      render_table(scroll_y: true)
      expect(page).to have_no_css("table[data-controller]")
    end

    it "turns rows into cards below 768px only when stacked (C26, C73)" do
      render_table(stacked: true)
      expect(page).to have_css("table.ui-table.ui-table--stacked")
    end

    it "switches to compact rows (C53)" do
      render_table(compact: true)
      expect(page).to have_css("table.ui-table--compact")
    end

    it "keeps the first, the last or both columns sticky (C59, C75)" do
      render_table(sticky: :first)
      expect(page).to have_css("table.ui-table--sticky-first")
      render_table(sticky: :last)
      expect(page).to have_css("table.ui-table--sticky-last")
      render_table(sticky: :both)
      expect(page).to have_css("table.ui-table--sticky-first.ui-table--sticky-last")
    end

    it "rejects an unknown sticky side" do
      expect { described_class.new(sticky: :middle) }.to raise_error(ArgumentError, /sticky/)
    end

    it "wires collapsible groups on the wrapper when grouped (C57)" do
      render_table(grouped: true)
      expect(page).to have_css("[data-controller~='ui--row-group'] table")
    end
  end

  describe "#column_count" do
    it "counts the header cells so full-width rows span the whole table" do
      component = described_class.new
      render_inline(component) do |t|
        t.with_head { "<th>A</th><th scope=\"col\">B</th><th class=\"x\">C</th>".html_safe }
        "<tr><td colspan=\"#{t.column_count}\">x</td></tr>".html_safe
      end
      expect(page).to have_css("td[colspan='3']")
    end

    it "is at least one without a header" do
      component = described_class.new
      render_inline(component) { "" }
      expect(component.column_count).to eq(1)
    end
  end

  describe "state slot (C51)" do
    def render_with_state(**state)
      render_inline(described_class.new) do |t|
        t.with_head { "<th>A</th><th>B</th>".html_safe }
        t.with_state(**state)
        ""
      end
    end

    it "renders the state inside the body, under the headers, across every column" do
      render_with_state(kind: :empty, title: "No secrets yet")
      expect(page).to have_css("thead th", count: 2)
      expect(page).to have_css("tbody tr.ui-table-state td[colspan='2']", text: "No secrets yet")
    end

    it "renders no state row without the slot" do
      render_table
      expect(page).to have_no_css("tr.ui-table-state")
    end
  end

  describe "foot slot" do
    it "renders a tfoot for totals" do
      render_inline(described_class.new) do |t|
        t.with_head { "<th>A</th>".html_safe }
        t.with_foot { "<tr><td>Total</td></tr>".html_safe }
        ""
      end
      expect(page).to have_css("table tfoot tr td", text: "Total")
    end
  end

  # C56 — multiple selection: the table owns the "select all" box, each row its own box.
  describe "selectable" do
    it "puts a select-all checkbox in front of the headers, wired to the bulk selection" do
      render_inline(described_class.new(selectable: { test_id: "errors-select-all" })) do |t|
        t.with_head { "<th>A</th>".html_safe }
        ""
      end
      box = page.find("thead th:first-child input[type='checkbox']")
      expect(box["data-ui--bulk-select-target"]).to eq("all")
      expect(box["data-action"]).to eq("change->ui--bulk-select#toggleAll")
      expect(box["data-test"]).to eq("errors-select-all")
      expect(box["aria-label"]).to eq(I18n.t("shared.bulk_triage.select_all"))
    end

    it "counts the selection column in column_count" do
      component = described_class.new(selectable: true)
      render_inline(component) do |t|
        t.with_head { "<th>A</th><th>B</th>".html_safe }
        "<tr><td colspan=\"#{t.column_count}\">x</td></tr>".html_safe
      end
      expect(page).to have_css("td[colspan='3']")
    end

    it "renders no selection column by default" do
      render_table
      expect(page).to have_no_css("input[type='checkbox']")
    end
  end
end
