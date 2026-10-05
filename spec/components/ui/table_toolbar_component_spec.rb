# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::TableToolbarComponent, type: :component do
  it "rende un form GET con search e conteggio" do
    render_inline(described_class.new(url: "/things", query: "abc", search_placeholder: "Search…",
                                      count: "5 things", search_test_id: "things-search", test_id: "things-toolbar"))

    expect(page).to have_css("form[action='/things'][method='get']")
    expect(page).to have_css("input[name='q'][value='abc'][data-test='things-search']")
    expect(page).to have_text("5 things")
  end

  # CYRA-883 — the bar sits on the page ground, stays at the top while scrolling, and says how to
  # reach it from the keyboard and how to empty it.
  describe "layout and search helpers" do
    it "is bare and sticky by default" do
      render_inline(described_class.new(url: "/things", search_placeholder: "Search…", test_id: "things-toolbar"))

      bar = page.find("[data-test='things-toolbar']")
      expect(bar[:class].split).to include("sticky", "top-0", "bg-stone-100")
      expect(bar[:class].split).not_to include("border-b", "px-4")
    end

    it "keeps the in-panel look when framed" do
      render_inline(described_class.new(url: "/things", search_placeholder: "Search…", test_id: "things-toolbar", framed: true))

      bar = page.find("[data-test='things-toolbar']")
      expect(bar[:class].split).to include("border-b", "px-4")
      expect(bar[:class].split).not_to include("sticky")
    end

    it "shows the slash key hint and a clear button, each visible only in its own state" do
      render_inline(described_class.new(url: "/things", search_placeholder: "Search…", test_id: "things-toolbar"))

      hint = page.find("kbd[data-test='things-toolbar-search-hint'][aria-hidden='true']", text: "/")
      expect(hint[:class].split).to include("peer-focus:hidden", "peer-[:not(:placeholder-shown)]:hidden")
      clear = page.find("[data-test='things-toolbar-search-clear']")
      expect(clear[:class].split).to include("peer-placeholder-shown:hidden")
    end

    # The clear is a button of the same form (never a submit: Enter must keep searching). Its
    # controller empties the field and submits, so the filters and the remembered-filters marker travel along.
    it "wires the clear button to empty the field and submit its own form" do
      render_inline(described_class.new(url: "/things", query: "abc", search_placeholder: "Search…", test_id: "things-toolbar"))

      clear = page.find("form [data-controller='ui--search-clear'] button[type='button'][data-test='things-toolbar-search-clear']")
      expect(clear[:"data-action"]).to eq("ui--search-clear#clear")
      expect(clear[:"aria-label"]).to eq(I18n.t("shared.tables.clear_search"))
      expect(page).to have_css("input[name='q'][data-ui--search-clear-target='input']")
      expect(page).to have_css("form input[type='hidden'][name='#{RememberableFilters::MARKER_PARAM}']", visible: :all)
    end
  end

  it "rende i filtri come chip nascosti + menu Filtri + Apply nel DOM" do
    render_inline(described_class.new(url: "/things", search_placeholder: "Search…", test_id: "things-toolbar")) do |toolbar|
      toolbar.with_filter(key: "status_id", label: "Status") { "<div data-test='my-filter'>F</div>".html_safe }
    end

    # Chip nascosto via ATTRIBUTO hidden (nessun param attivo) ma nel DOM col suo contenuto.
    expect(page).to have_css("[data-test='my-filter']", visible: :all)
    expect(page).to have_css("[data-test='filter-chip-status_id'][hidden]", visible: :all)
    expect(page).to have_css("button[type='button'][data-test='filter-chip-status_id-remove']", visible: :all)
    # Menu "Filtri": una voce per filtro, check nascosto se inattivo.
    expect(page).to have_css("[data-test='things-toolbar-filters-menu']")
    expect(page).to have_css("[data-test='filter-menu-status_id']", text: "Status")
    expect(page).to have_css("[data-test='filter-menu-status_id'] [data-menu-check][hidden]", visible: :all)
    # Apply resta nel DOM (fallback no-JS + system spec rack_test): lo nasconde il JS a runtime.
    expect(page).to have_css("button[type='submit'][data-test='things-toolbar-apply']")
    expect(page).to have_css("[data-controller='ui--filter-bar']")
  end

  it "con param attivo: chip visibile e check acceso nel menu" do
    with_request_url "/login?status_id[]=abc" do
      render_inline(described_class.new(url: "/things", test_id: "things-toolbar")) do |toolbar|
        toolbar.with_filter(key: "status_id", label: "Status") { "<div>F</div>".html_safe }
      end
    end

    expect(page).to have_css("[data-test='filter-chip-status_id']:not([hidden])")
    expect(page).to have_css("[data-test='filter-menu-status_id'] [data-menu-check]:not([hidden])")
  end

  it "rende i controls sempre visibili, senza wrapper chip" do
    render_inline(described_class.new(url: "/things")) do |toolbar|
      toolbar.with_control { "<div data-test='my-control'>C</div>".html_safe }
    end

    expect(page).to have_css("[data-test='my-control']")
    expect(page).to have_no_css("[data-ui--filter-bar-target='chip']")
    # I controls da soli non attivano menu né Stimulus: servono solo coi filtri.
    expect(page).to have_no_css("[data-controller='ui--filter-bar']")
  end

  it "senza filtri: nessun Apply, nessun menu, nessun controller Stimulus" do
    render_inline(described_class.new(url: "/things", search_placeholder: "Search…", test_id: "things-toolbar"))

    expect(page).to have_no_css("[data-test='things-toolbar-apply']")
    expect(page).to have_no_css("[data-test='things-toolbar-filters-menu']")
    expect(page).to have_no_css("[data-controller='ui--filter-bar']")
  end

  it "senza search_placeholder: nessuna search box" do
    render_inline(described_class.new(url: "/things", count: "0 things"))
    expect(page).to have_no_css("input[name='q']")
  end

  it "preserva i param sort correnti come hidden field nel form (sort e *_sort)" do
    with_request_url "/login?sort=-title&invitations_sort=email&status_id[]=abc" do
      render_inline(described_class.new(url: "/things"))
    end

    expect(page).to have_css("form input[type='hidden'][name='sort'][value='-title']", visible: :all)
    expect(page).to have_css("form input[type='hidden'][name='invitations_sort'][value='email']", visible: :all)
    # Gli altri param NON vengono replay-ati: i filtri viaggiano coi loro select.
    expect(page).to have_no_css("input[name='status_id[]']", visible: :all)
  end

  it "senza sort nei param: nessun hidden field aggiunto" do
    with_request_url "/login?q=x" do
      render_inline(described_class.new(url: "/things"))
    end

    expect(page).to have_no_css("input[type='hidden'][name='sort']", visible: :all)
  end

  it "una chiave sort già in hidden: non viene duplicata" do
    with_request_url "/login?sort=-title" do
      render_inline(described_class.new(url: "/things", hidden: { sort: "name" }))
    end

    expect(page).to have_css("input[type='hidden'][name='sort']", visible: :all, count: 1)
    expect(page).to have_css("input[type='hidden'][name='sort'][value='name']", visible: :all)
  end

  it "con semantic_search: freccia di ricerca (submit + semantic=1) e form che targetta il frame" do
    render_inline(described_class.new(url: "/things", search_placeholder: "Search…",
                                      results_frame: "things-results", semantic_search: true,
                                      search_submit_test_id: "things-search-submit")) do |toolbar|
      toolbar.with_filter(key: "x", label: "X") { "<div data-test='my-filter'>F</div>".html_safe }
    end

    # Il form targetta il turbo-frame (risultati in place) e guida lo stato di caricamento.
    expect(page).to have_css("form[data-turbo-frame='things-results']")
    expect(page).to have_css("[data-controller='ui--filter-bar']")
    # Search arrow inside the field (submit, spinner target) + hidden semantic=1. CYRA-902
    expect(page).to have_css("[data-controller~='ui--search-clear'] button[type='submit'][data-test='things-search-submit'][data-ui--filter-bar-target='submitButton']")
    expect(page).to have_css("input[type='hidden'][name='semantic'][value='1']", visible: :all)
    # Regione filtri dim-abile durante il caricamento.
    expect(page).to have_css("[data-ui--filter-bar-target='filterRegion'] [data-test='my-filter']", visible: :all)
  end

  it "con semantic_selectable: selettore di modalità al posto dell'hidden fisso (CYRA-417)" do
    render_inline(described_class.new(url: "/things", search_placeholder: "Cerca…",
                                      results_frame: "things-results", semantic_search: true,
                                      semantic_selectable: true, search_submit_test_id: "things-search-submit")) do |toolbar|
      toolbar.with_filter(key: "x", label: "X") { "<div>F</div>".html_safe }
    end

    # The mode travels in a hidden field, picked from a design-system listbox (no native select).
    expect(page).to have_css("input[type='hidden'][name='semantic'][value='1']", visible: :all)
    expect(page).to have_no_css("select[name='semantic']", visible: :all)
    expect(page).to have_css("[role='listbox'] [role='option'][data-value='1']", visible: :all)
    expect(page).to have_css("[role='listbox'] [role='option'][data-value='0']", visible: :all)
    # The search still starts only on an explicit action: the arrow inside the field.
    expect(page).to have_css("button[type='submit'][data-test='things-search-submit']")
  end

  # CYRA-902 — the mode is an icon picker at the start of the field, and the placeholder says the mode.
  it "puts the search mode picker inside the search field" do
    render_inline(described_class.new(url: "/things", search_placeholder: "Search…", test_id: "things-toolbar",
                                      semantic_search: true, semantic_selectable: true))

    field = page.find("[data-controller~='ui--search-mode']")
    trigger = field.find("button[type='button'][aria-haspopup='listbox'][data-test='things-toolbar-search-mode']")
    expect(trigger[:"aria-expanded"]).to eq("false")
    expect(trigger[:"aria-label"]).to eq(I18n.t("shared.tables.search_mode.label"))
    expect(field).to have_css("input[type='hidden'][name='semantic'][data-ui--search-mode-target='value']", visible: :all)
    expect(field).to have_css("ul[role='listbox'][data-ui--search-mode-target='menu'][hidden]", visible: :all)
    expect(field).to have_css("input[name='q'][data-ui--search-mode-target='input']")
    semantic = I18n.t("shared.tables.search_mode.semantic").downcase_first
    expect(field.find("input[name='q']")[:placeholder]).to eq("Search… · #{semantic}")
    exact = field.find("[role='option'][data-value='0']", visible: :all)
    expect(exact[:"data-placeholder"]).to eq("Search… · #{I18n.t('shared.tables.search_mode.exact').downcase_first}")
    expect(exact[:"data-action"]).to eq("ui--search-mode#choose")
  end

  it "every search field has the search arrow, also without filters or semantic search" do
    render_inline(described_class.new(url: "/things", search_placeholder: "Search…", test_id: "things-toolbar"))

    arrow = page.find("[data-controller~='ui--search-clear'] button[type='submit'][data-test='things-toolbar-search-submit']")
    expect(arrow[:"aria-label"]).to eq(I18n.t("shared.tables.search"))
  end

  describe "the View menu: group by and saved views (C62, CYRA-924)" do
    let(:group_by) do
      [ { label: "Uptime group", href: "/things?view=grouped", active: true, test_id: "group-grouped" },
        { label: "None", hint: "one list", href: "/things?view=table", active: false, test_id: "group-table" } ]
    end

    it "renders the saved views inside the View menu, outside the GET form and the Filters menu" do
      render_inline(described_class.new(url: "/things", test_id: "things-toolbar")) do |toolbar|
        toolbar.with_filter(key: "x", label: "X") { "<div>F</div>".html_safe }
        toolbar.with_views { "<div data-test='my-views'>V</div>".html_safe }
      end

      expect(page).to have_css("[data-test='things-toolbar-view-menu'] [data-test='my-views']", visible: :all)
      expect(page).to have_no_css("[data-ui--filter-bar-target='menuPanel'] [data-test='my-views']", visible: :all)
      expect(page).to have_no_css("form [data-test='my-views']", visible: :all)
    end

    it "has no Filters menu when the page has saved views but no filters" do
      render_inline(described_class.new(url: "/things", search_placeholder: "Search…", test_id: "things-toolbar")) do |toolbar|
        toolbar.with_views { "<div data-test='my-views'>V</div>".html_safe }
      end

      expect(page).to have_no_css("[data-test='things-toolbar-filters-menu']")
      expect(page).to have_css("[data-test='things-toolbar-view-menu'] [data-test='my-views']", visible: :all)
    end

    it "lists the group-by choices as menu links, with a check on the active one" do
      render_inline(described_class.new(url: "/things", test_id: "things-toolbar", group_by: group_by))

      menu = page.find("[data-test='things-toolbar-view-menu']", visible: :all)
      expect(menu).to have_text(I18n.t("shared.tables.group_by"), normalize_ws: true)
      expect(menu).to have_link("Uptime group", href: "/things?view=grouped", visible: :all)
      expect(menu).to have_link("None", href: "/things?view=table", visible: :all)
      expect(menu.find("a[data-test='group-grouped']", visible: :all)[:"aria-current"]).to eq("true")
      expect(menu).to have_css("a[data-test='group-grouped'] svg[data-icon='check']", visible: :all)
      expect(menu).to have_no_css("a[data-test='group-table'] svg[data-icon='check']", visible: :all)
      expect(menu).to have_text("one list", normalize_ws: true)
    end

    it "keeps the View menu as the rightmost item, after controls that ask for the end" do
      render_inline(described_class.new(url: "/things", test_id: "things-toolbar", group_by: group_by)) do |toolbar|
        toolbar.with_control { "<div class='order-last' data-test='late-control'>C</div>".html_safe }
      end

      menu = page.find("[data-test='things-toolbar-view-menu']", visible: :all)
      expect(menu[:class].split).to include("order-last", "ml-auto")
      expect(page.native.to_html.index("things-toolbar-view-menu")).to be > page.native.to_html.index("late-control")
    end

    # CYRA-924 — how the list is shown (cards or table, board or list) and how cards sort live in the
    # View menu too, as sections of their own above the group-by choices.
    it "renders extra sections above the group-by, with link or preference-button choices" do
      sections = [
        { heading: "Show as", data: { controller: "switcher" }, choices: [
          { label: "Cards", form: "cards-form", active: true, test_id: "show-cards" },
          { label: "Table", href: "/things?as=table", active: false, test_id: "show-table",
            data: { action: "click->switcher#follow" } }
        ] },
        { heading: "Sort", choices: [ { label: "Name", href: "/things?sort=name", active: true, test_id: "sort-name" } ] }
      ]
      render_inline(described_class.new(url: "/things", test_id: "things-toolbar", view_sections: sections,
                                        group_by: group_by))

      menu = page.find("[data-test='things-toolbar-view-menu']", visible: :all)
      button = menu.find("button[data-test='show-cards']", visible: :all)
      expect(button[:type]).to eq("submit")
      expect(button[:form]).to eq("cards-form")
      expect(button[:"aria-current"]).to eq("true")
      expect(button).to have_css("svg[data-icon='check']", visible: :all)
      link = menu.find("a[data-test='show-table']", visible: :all)
      expect(link[:href]).to eq("/things?as=table")
      expect(link[:"data-action"]).to eq("click->switcher#follow")
      expect(menu).to have_css("[data-controller='switcher'] a[data-test='show-table']", visible: :all)
      html = menu.native.to_html
      expect(html.index("Show as")).to be < html.index("Sort")
      expect(html.index("Sort")).to be < html.index(I18n.t("shared.tables.group_by"))
    end

    it "opens a View menu for extra sections alone" do
      sections = [ { heading: "Show as", choices: [ { label: "Board", href: "/b", active: true, test_id: "show-board" } ] } ]
      render_inline(described_class.new(url: "/things", test_id: "things-toolbar", view_sections: sections))

      expect(page).to have_css("[data-test='things-toolbar-view-menu'] a[data-test='show-board']", visible: :all)
    end

    it "has no View menu without group-by choices or saved views" do
      render_inline(described_class.new(url: "/things", search_placeholder: "Search…", test_id: "things-toolbar"))

      expect(page).to have_no_css("[data-test='things-toolbar-view-menu']", visible: :all)
    end
  end

  it "semantic_selectable: default per significato, e riflette la scelta corrente dai params" do
    render_inline(described_class.new(url: "/things", search_placeholder: "Cerca…",
                                      results_frame: "things-results", semantic_search: true, semantic_selectable: true))
    # Without the param the default mode is by meaning (value 1).
    expect(page).to have_css("input[name='semantic'][value='1']", visible: :all)
    expect(page).to have_css("[role='option'][data-value='1'][aria-selected='true']", visible: :all)

    with_request_url "/login?semantic=0" do
      render_inline(described_class.new(url: "/things", search_placeholder: "Cerca…",
                                        results_frame: "things-results", semantic_search: true, semantic_selectable: true))
    end
    # Exact words chosen: reflected in the field and the listbox (reversible).
    expect(page).to have_css("input[name='semantic'][value='0']", visible: :all)
    expect(page).to have_css("[role='option'][data-value='0'][aria-selected='true']", visible: :all)
  end

  it "senza semantic_search: nessun selettore di modalità né frame (le altre index invariate)" do
    render_inline(described_class.new(url: "/things", search_placeholder: "Search…")) do |toolbar|
      toolbar.with_filter(key: "x", label: "X") { "<div>F</div>".html_safe }
    end

    expect(page).to have_no_css("form[data-turbo-frame]")
    expect(page).to have_no_css("input[name='semantic']", visible: :all)
    expect(page).to have_no_css("[data-ui--filter-bar-target='filterRegion']", visible: :all)
  end

  it "il trailing resta fuori dal form GET" do
    render_inline(described_class.new(url: "/things")) do |toolbar|
      toolbar.with_filter(key: "x", label: "X") { "<div>F</div>".html_safe }
      toolbar.with_trailing { "<div data-test='my-trailing'>T</div>".html_safe }
    end

    expect(page).to have_css("[data-test='my-trailing']")
    expect(page).to have_no_css("form [data-test='my-trailing']")
  end

  # CYRA-694 — il marker dei filtri ricordati: ogni submit dichiara «questi sono TUTTI i filtri».
  it "il form porta sempre il marker ft=1 quando ci sono filtri o ricerca" do
    render_inline(described_class.new(url: "/things", search_placeholder: "Search…"))
    expect(page).to have_css("form input[type='hidden'][name='ft'][value='1']", visible: :all)
  end

  it "senza filtri né ricerca il marker non c'è (l'indirizzo resta pulito)" do
    render_inline(described_class.new(url: "/things", count: "0 things"))
    expect(page).to have_no_css("input[name='ft']", visible: :all)
  end

  it "con un filtro attivo offre «Azzera filtri», che porta il marker" do
    with_request_url "/login?status_id[]=abc" do
      render_inline(described_class.new(url: "/things", test_id: "things-toolbar")) do |toolbar|
        toolbar.with_filter(key: "status_id", label: "Status") { "<div>F</div>".html_safe }
      end
    end

    azzera = page.find("[data-test='things-toolbar-reset']")
    expect(azzera[:href]).to eq("/things?ft=1")
  end

  it "senza filtri attivi né ricerca scritta il collegamento Azzera non c'è" do
    render_inline(described_class.new(url: "/things", search_placeholder: "Search…", test_id: "things-toolbar")) do |toolbar|
      toolbar.with_filter(key: "status_id", label: "Status") { "<div>F</div>".html_safe }
    end

    expect(page).to have_no_css("[data-test='things-toolbar-reset']")
  end

  it "porta il marker anche quando c'è solo il filtro, senza ricerca" do
    render_inline(described_class.new(url: "/things")) do |toolbar|
      toolbar.with_filter(key: "status_id", label: "Status") { "<div>F</div>".html_safe }
    end

    expect(page).to have_css("form input[type='hidden'][name='ft'][value='1']", visible: :all)
  end

  it "su un url che ha già una query, Azzera si accoda con &" do
    with_request_url "/login?status_id[]=abc" do
      render_inline(described_class.new(url: "/things?scope=mine", test_id: "things-toolbar")) do |toolbar|
        toolbar.with_filter(key: "status_id", label: "Status") { "<div>F</div>".html_safe }
      end
    end

    expect(page.find("[data-test='things-toolbar-reset']")[:href]).to eq("/things?scope=mine&ft=1")
  end

  it "senza test_id il collegamento Azzera ha il data-test di ripiego" do
    with_request_url "/login?status_id[]=abc" do
      render_inline(described_class.new(url: "/things")) do |toolbar|
        toolbar.with_filter(key: "status_id", label: "Status") { "<div>F</div>".html_safe }
      end
    end

    expect(page).to have_css("[data-test='toolbar-reset']")
  end

  it "anche la sola ricerca scritta accende Azzera" do
    render_inline(described_class.new(url: "/things", query: "abc", search_placeholder: "Search…", test_id: "things-toolbar"))

    expect(page).to have_css("[data-test='things-toolbar-reset']")
  end

  it "il campo di ricerca espone un focus ring visibile ad AA (indigo-500 su focus-visible)" do
    render_inline(described_class.new(url: "/things", search_placeholder: "Search…"))
    html = page.native.to_html
    expect(html).to include("focus-visible:ring-indigo-500")
    expect(html).not_to include("focus:ring-indigo-100")
  end
end
