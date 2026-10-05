# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::TableComponent::HeaderComponent, type: :component do
  def query_of(href)
    Rack::Utils.parse_nested_query(URI.parse(href).query.to_s)
  end

  # CYRA-670 — un <th> senza scope non dichiara di intestare la colonna: chi naviga con lo screen
  # reader sente il valore della cella senza mai sentire il nome della colonna a cui appartiene.
  it "ogni intestazione dichiara la propria colonna con scope=col" do
    render_inline(described_class.new(label: "Uptime"))

    expect(page).to have_css("th[scope='col']", text: "Uptime")
  end

  it "scope=col anche sull'intestazione ordinabile" do
    with_request_url "/login?sort=title" do
      render_inline(described_class.new(label: "Title", sort: "title"))
    end

    expect(page).to have_css("th[scope='col'][aria-sort='ascending']")
  end

  it "senza sort: <th> statico con lo stile standard, niente link né icona" do
    render_inline(described_class.new(label: "Uptime"))

    expect(page).to have_css("th.font-mono", text: "Uptime")
    expect(page).to have_no_css("th a")
    expect(page).to have_no_css("th i")
  end

  it "neutral sortable: a link with the arrow-up-down icon and a URL that sets the key ascending" do
    with_request_url "/login" do
      render_inline(described_class.new(label: "Title", sort: "title"))
    end

    expect(page).to have_css("th a[data-test='sort-title']", text: "Title")
    expect(page).to have_css("th a svg[data-icon='arrow-up-down']")
    expect(page).to have_no_css("th[aria-sort]")
    expect(query_of(page.find("th a")[:href])["sort"]).to eq("title")
  end

  it "attivo asc: aria-sort=ascending, freccia su, il link inverte a -chiave" do
    with_request_url "/login?sort=title" do
      render_inline(described_class.new(label: "Title", sort: "title"))
    end

    expect(page).to have_css("th[aria-sort='ascending']")
    expect(page).to have_css("th a svg[data-icon='arrow-up']")
    expect(query_of(page.find("th a")[:href])["sort"]).to eq("-title")
  end

  it "attivo desc: aria-sort=descending, freccia giù, il link torna ascendente" do
    with_request_url "/login?sort=-title" do
      render_inline(described_class.new(label: "Title", sort: "title"))
    end

    expect(page).to have_css("th[aria-sort='descending']")
    expect(page).to have_css("th a svg[data-icon='arrow-down']")
    expect(query_of(page.find("th a")[:href])["sort"]).to eq("title")
  end

  it "un'altra colonna attiva → questa resta neutra" do
    with_request_url "/login?sort=-code" do
      render_inline(described_class.new(label: "Title", sort: "title"))
    end

    expect(page).to have_css("th a svg[data-icon='arrow-up-down']")
    expect(page).to have_no_css("th[aria-sort]")
  end

  it "initial: :desc → il primo click parte discendente" do
    with_request_url "/login" do
      render_inline(described_class.new(label: "Last seen", sort: "last_seen", initial: :desc))
    end

    expect(query_of(page.find("th a")[:href])["sort"]).to eq("-last_seen")
  end

  it "il toggle preserva i filtri correnti e azzera solo la propria pagina" do
    with_request_url "/login?status_id[]=abc&q=boom&page=3&sort=title" do
      render_inline(described_class.new(label: "Title", sort: "title"))
    end

    query = query_of(page.find("th a")[:href])
    expect(query["status_id"]).to eq([ "abc" ])
    expect(query["q"]).to eq("boom")
    expect(query["sort"]).to eq("-title")
    expect(query).not_to have_key("page")
  end

  it "param e page_param custom: tocca solo il proprio namespace (seconda tabella)" do
    with_request_url "/login?invitations_sort=email&invitations_page=2&page=5" do
      render_inline(described_class.new(label: "Email", sort: "email",
                                        param: :invitations_sort, page_param: :invitations_page))
    end

    expect(page).to have_css("th[aria-sort='ascending']")
    query = query_of(page.find("th a")[:href])
    expect(query["invitations_sort"]).to eq("-email")
    expect(query["page"]).to eq("5")
    expect(query).not_to have_key("invitations_page")
  end

  it "align: :right e classi extra si sommano allo stile base" do
    with_request_url "/login" do
      render_inline(described_class.new(label: "Events", sort: "events", align: :right, classes: "w-20"))
    end

    expect(page).to have_css("th.text-right.w-20.font-mono")
  end

  # CYRA-492 — un ordinamento di default diverso dall'alfabetico va dichiarato sull'intestazione, o
  # sorprende chi si aspetta l'ordine per nome.
  it "hint: aggiunge un'icona info col tooltip, senza toccare il link di ordinamento" do
    with_request_url "/login" do
      render_inline(described_class.new(label: "Status", sort: "status", hint: "Non sani prima"))
    end

    expect(page).to have_css("th a", text: "Status")
    expect(page).to have_css("th svg[data-icon='info'][aria-label='Non sani prima']")
  end

  it "senza hint: nessuna icona info" do
    render_inline(described_class.new(label: "Status"))

    expect(page).to have_no_css("svg[data-icon='info']")
  end

  it "aria-label i18n sul link e test_id overridabile" do
    with_request_url "/login" do
      render_inline(described_class.new(label: "Title", sort: "title", test_id: "custom-sort"))
    end

    expect(page).to have_css("th a[data-test='custom-sort']")
    expect(page.find("th a")[:"aria-label"]).to include("Title")
  end

  # CYRA-924 — a static header carries its test id on the <th>, so no page writes one by hand (C49).
  it "puts the test id on the th of a static header" do
    render_inline(described_class.new(label: "Steps", test_id: "steps-head"))

    expect(page).to have_css("th[data-test='steps-head']", text: "Steps")
  end

  # CYRA-924 — C76: a column that says nothing in this view is hidden by the component.
  it "renders nothing when the column is hidden" do
    render_inline(described_class.new(label: "Project", visible: false))

    expect(page).to have_no_css("th")
  end

  # CYRA-924 — C49: the narrow "open" column is declared through the component, label for screen readers only.
  it "keeps a hidden label for screen readers and drops the side padding" do
    render_inline(described_class.new(label: "Open", label_hidden: true))

    expect(page).to have_css("th[scope='col'] span.sr-only", text: "Open")
    expect(page).to have_no_css("th.px-4")
  end

  it "keeps a fixed width on a hidden-label column" do
    render_inline(described_class.new(label: "Edit", label_hidden: true, classes: "w-10"))

    expect(page).to have_css("th.w-10 span.sr-only", text: "Edit")
  end
end
