# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::PageHeaderComponent, type: :component do
  it "rende il titolo in un h1" do
    render_inline(described_class.new(title: "Nuovo progetto"))
    expect(page).to have_css("h1.font-display", text: "Nuovo progetto")
  end

  it "rende il tooltip informativo accanto al titolo quando passato title_tooltip" do
    render_inline(described_class.new(title: "Tickets", title_tooltip: "Cosa trovi qui"))

    expect(page).to have_css("[data-controller='ui--tooltip']")
    expect(page).to have_css("[role='tooltip']", text: "Cosa trovi qui", visible: :all)
  end

  it "non rende alcun tooltip senza title_tooltip" do
    render_inline(described_class.new(title: "Tickets"))
    expect(page).not_to have_css("[data-controller='ui--tooltip']")
  end

  it "non rende il link back senza back_href" do
    render_inline(described_class.new(title: "Titolo"))
    expect(page).not_to have_css("a")
  end

  it "rende il link back con back_href e back_label" do
    render_inline(described_class.new(title: "Titolo", back_href: "/x", back_label: "Indietro"))
    expect(page).to have_css("a[href='/x']", text: "Indietro")
  end

  it "renders the actions slot on the title row (DESIGN.md B2)" do
    render_inline(described_class.new(title: "Titolo")) do |h|
      h.with_actions { "<button>Salva</button>".html_safe }
    end
    expect(page).to have_css("div[data-test='page-header-actions'] button", text: "Salva")
  end

  it "rende lo slot meta sotto il titolo" do
    render_inline(described_class.new(title: "Titolo")) do |h|
      h.with_meta { "<span data-test='pill'>creato oggi</span>".html_safe }
    end
    expect(page).to have_css("[data-test='pill']", text: "creato oggi")
  end

  it "espone il data-test sul contenitore" do
    render_inline(described_class.new(title: "T", test_id: "page-header"))
    expect(page).to have_css("[data-test='page-header']")
  end

  # CYRA-883 — a trail that only names the current page repeats the h1 and is not rendered.
  it "hides the breadcrumb when the trail only repeats the title" do
    render_inline(described_class.new(title: "Tickets", breadcrumb: [ { label: "Tickets" } ]))

    expect(page).not_to have_css("nav[data-test='breadcrumb']")
    expect(page).to have_css("h1", text: "Tickets")
  end

  # B22 — the lone crumb still leads somewhere when the page sits in an area: the trail adds the area level.
  it "shows the area level when the lone crumb repeats the title of a page inside an area" do
    with_controller_class(Member::TicketsController) do
      render_inline(described_class.new(title: "Tickets", breadcrumb: [ { label: "Tickets" } ]))
    end

    expect(page).to have_css("nav[data-test='breadcrumb'] a", text: I18n.t("member.nav.group_product"))
    expect(page).to have_css("nav[data-test='breadcrumb'] [aria-current='page']", text: "Tickets")
  end

  it "hides the lone crumb on a pinned page, which has no area level" do
    with_controller_class(Member::GuidesController) do
      render_inline(described_class.new(title: "Guides", breadcrumb: [ { label: "Guides" } ]))
    end

    expect(page).not_to have_css("nav[data-test='breadcrumb']")
  end

  it "hides the breadcrumb when the trail is empty" do
    render_inline(described_class.new(title: "Dashboard", breadcrumb: []))

    expect(page).not_to have_css("nav[data-test='breadcrumb']")
  end

  it "keeps the breadcrumb when the trail leads back through another page" do
    render_inline(described_class.new(title: "CYRA-1", breadcrumb: [ { label: "Tickets", href: "/member/tickets" }, { label: "CYRA-1" } ]))

    expect(page).to have_css("nav[data-test='breadcrumb'] a[href='/member/tickets']", text: "Tickets")
    expect(page).to have_css("[data-test='breadcrumb-crumb']", text: I18n.t("member.nav.home"))
  end

  it "la breadcrumb ha priorità sul back link quando entrambi presenti" do
    render_inline(described_class.new(title: "T", breadcrumb: [ { label: "X", href: "/x" }, { label: "T" } ], back_href: "/y", back_label: "Indietro"))

    expect(page).to have_css("nav[data-test='breadcrumb']")
    expect(page).not_to have_css("a svg[data-icon='chevron-left']")
    expect(page).not_to have_css("a", text: "Indietro")
  end

  # DESIGN.md B25 — in the member area the header collapses to title, actions, tabs and counts.
  describe "collapsing (B25)" do
    def render_member_header(**args)
      with_controller_class(Member::TicketsController) do
        render_inline(described_class.new(title: "Tickets", subtitle: "The team's tickets.",
                                          breadcrumb: [ { label: "Tickets" } ], **args)) do |header|
          header.with_actions { "<a data-test='new'>New</a>".html_safe }
        end
      end
    end

    it "sticks to the top and carries a toggle after the actions, expanded by default" do
      render_member_header

      header = page.find("header[data-controller~='ui--page-header']")
      expect(header[:class]).to include("sticky")
      expect(header["data-collapsed"]).to be_nil
      toggle = header.find("[data-test='page-header-collapse']")
      expect(toggle["aria-expanded"]).to eq("true")
      expect(toggle["aria-label"]).to eq(I18n.t("ui.page_header.collapse"))
      expect(header).to have_css("[data-test='page-header-actions'] [data-test='new'] ~ [data-test='page-header-collapse']", visible: :all)
    end

    # A page header inside a dialog the page renders itself (New Puck): nothing to collapse.
    it "renders no toggle and no sticky frame with collapsible: false" do
      render_member_header(collapsible: false)

      expect(page).to have_no_css("[data-test='page-header-collapse']", visible: :all)
      expect(page).to have_no_css("header[data-controller~='ui--page-header']")
    end

    it "hides the breadcrumb and the subtitle when collapsed, never the title" do
      render_member_header

      expect(page).to have_css(".group-data-\\[collapsed\\]\\/header\\:hidden nav[data-test='breadcrumb']")
      expect(page.find("[data-test='page-header-subtitle']")[:class]).to include("group-data-[collapsed]/header:hidden")
      expect(page.find("h1")[:class]).not_to include("hidden")
    end

    it "has no toggle outside the member area" do
      render_inline(described_class.new(title: "Valhalla"))

      expect(page).not_to have_css("[data-controller~='ui--page-header']")
      expect(page).not_to have_css("[data-test='page-header-collapse']")
    end
  end

  # DESIGN.md T2 — the header is a panel; tabs and counts share its bottom row.
  it "renders the header as a panel" do
    render_inline(described_class.new(title: "Tickets", test_id: "page-header"))

    expect(page).to have_css("header[data-test='page-header'].rounded-lg.border.border-stone-200.bg-white")
  end

  it "lets a tab carry an amber count and a trailing mark of its own" do
    render_inline(described_class.new(title: "Ticket")) do |h|
      h.with_tab(label: "Questions", href: "/q", count: 2, count_color: :amber, count_test_id: "q-count")
      h.with_tab(label: "Report", href: "/r") { "<span data-test='version'>v2</span>".html_safe }
    end

    expect(page.find("[data-test='q-count']")[:class]).to include("bg-amber-100")
    expect(page).to have_css("a[href='/r'] [data-test='version']", text: "v2")
  end

  it "draws no bottom row without tabs or counts" do
    render_inline(described_class.new(title: "Tickets"))

    expect(page).not_to have_css("[data-test='page-header-bottom']")
  end

  it "renders the counts at the right end of the bottom row, even without tabs" do
    render_inline(described_class.new(title: "Tickets", counts_test_id: "tickets-counts")) do |h|
      h.with_counts { "<span data-test='chip'>12 tickets</span>".html_safe }
    end

    expect(page).to have_css("[data-test='page-header-bottom'] [data-test='tickets-counts'].ml-auto [data-test='chip']", text: "12 tickets")
    expect(page).not_to have_css("[data-test='page-header-title-row'] [data-test='tickets-counts']")
  end

  it "renders the tabs inside the panel, before the counts, marking the active one" do
    render_inline(described_class.new(title: "Uptime", tabs_test_id: "uptime-tabs", counts_test_id: "hdr-counts")) do |h|
      h.with_tab(label: "Monitors", href: "/monitors", active: true, icon: "heart-pulse", test_id: "tab-monitors")
      h.with_tab(label: "Incidents", href: "/incidents", test_id: "tab-incidents")
      h.with_counts { "<span>3 up</span>".html_safe }
    end

    bottom = page.find("[data-test='page-header-bottom']")
    expect(bottom).to have_css("[data-test='uptime-tabs'] a[data-test='tab-monitors'][aria-current='page'][href='/monitors']", text: "Monitors")
    expect(bottom).to have_css("a[data-test='tab-monitors'] svg[data-icon='heart-pulse']")
    expect(bottom).to have_css("a[data-test='tab-incidents']:not([aria-current])", text: "Incidents")
    expect(bottom).not_to have_css("[data-test='hdr-counts'].ml-auto")
    html = bottom.native.to_html
    expect(html.index("uptime-tabs")).to be < html.index("hdr-counts")
  end

  # DESIGN.md B14 — the least used tabs live in "More"; an active one names the trigger.
  it "puts the more tabs in a menu whose trigger names the active one" do
    render_inline(described_class.new(title: "Project")) do |h|
      h.with_tab(label: "Overview", href: "/p")
      h.with_more_tab(label: "Secrets", href: "/p/secrets", active: true, icon: "lock", test_id: "tab-secrets")
      h.with_more_tab(label: "Usage", href: "/p/usage", test_id: "tab-usage")
    end

    trigger = page.find("summary[data-test='page-header-tab-more']")
    expect(trigger[:"aria-current"]).to eq("page")
    expect(trigger).to have_text("Secrets")
    expect(page).to have_css("[data-test='page-header-tab-more-menu'] a[data-test='tab-usage']", text: "Usage", visible: :all)
  end

  it "names the more trigger generically when no more tab is active" do
    render_inline(described_class.new(title: "Project")) do |h|
      h.with_tab(label: "Overview", href: "/p", active: true)
      h.with_more_tab(label: "Usage", href: "/p/usage")
    end

    expect(page.find("summary[data-test='page-header-tab-more']")).to have_text(I18n.t("ui.page_header.more"))
  end

  # CYRA-883 — the member header carries no guide link: the subtitle says what the page holds.
  it "renders no guide link even on a page that has a guide" do
    with_request_url "/member/monitoring/monitors" do
      render_inline(described_class.new(title: "Controlli", subtitle: "Checks"))

      expect(page).not_to have_css("[data-test='page-header-guide']")
      expect(page).to have_css("[data-test='page-header-subtitle']", text: "Checks")
    end
  end

  # CYRA-883 — actions sit on the title row, right-aligned, and wrap below it on narrow screens.
  it "renders the actions on the title row, after the title block" do
    render_inline(described_class.new(title: "T", subtitle: "What is here")) do |h|
      h.with_actions { "<button>Salva</button>".html_safe }
    end

    row = page.find("[data-test='page-header-title-row']")
    expect(row).to have_css("h1", text: "T")
    expect(row).to have_css("[data-test='page-header-actions'].flex-wrap button", text: "Salva")
  end

  # DESIGN.md B11 — an object's page shows its color square, name and Mono code.
  it "renders the mark before the title and the badges after it" do
    render_inline(described_class.new(title: "Payments")) do |h|
      h.with_mark { "<span data-test='mark'>P</span>".html_safe }
      h.with_badges { "<span data-test='key'>PAY</span>".html_safe }
    end

    line = page.find("[data-test='page-header-title-row'] h1").ancestor("div", match: :first)
    html = line.native.to_html
    expect(html.index("data-test=\"mark\"")).to be < html.index("<h1")
    expect(html.index("<h1")).to be < html.index("data-test=\"key\"")
  end

  it "derives the inner test ids from test_id" do
    render_inline(described_class.new(title: "Payments", test_id: "project")) do |h|
      h.with_actions { "<button>New</button>".html_safe }
      h.with_more_tab(label: "Usage", href: "/u")
    end

    expect(page).to have_css("[data-test='project-title-row'] [data-test='project-actions'] button", text: "New")
    expect(page).to have_css("summary[data-test='project-tab-more']")
    expect(page).to have_css("[data-test='project-tab-more-menu']", visible: :all)
  end

  # CYRA-819 — on a phone the actions wrap under the title block: the meta must come before them.
  it "renders the meta inside the title block, before the actions" do
    render_inline(described_class.new(title: "Ticket")) do |h|
      h.with_meta { "<span data-test='summary'>Open</span>".html_safe }
      h.with_actions { "<button>Edit</button>".html_safe }
    end

    html = page.find("[data-test='page-header-title-row']").native.to_html
    expect(html.index("summary")).to be < html.index("page-header-actions")
  end
end
