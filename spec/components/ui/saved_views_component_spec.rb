# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::SavedViewsComponent, type: :component do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  def render_widget(views:, current_filters: {})
    render_inline(described_class.new(resource_type: "tickets", views: views,
                                      index_helper: :member_tickets_path, current_filters: current_filters))
  end

  # CYRA-924 — a section of the View menu: a title, no trigger of its own.
  it "renders a titled menu section with the 'save' entry; empty state without views" do
    render_widget(views: SavedView.none)
    expect(page).to have_no_css("[data-test='saved-views-trigger']")
    expect(page).to have_css("[data-test='saved-views']", text: I18n.t("shared.saved_views.section_title"))
    expect(page).to have_css("[data-test='saved-view-add']")
    expect(page).to have_css("[data-test='saved-views-empty']")
  end

  it "elenca le viste con link di applicazione (coi filtri salvati) ed elimina" do
    view = create(:saved_view, account: account, organization: organization, resource_type: "tickets",
                               name: "Aperti", filters: { "status_id" => [ "s1" ] })
    render_widget(views: SavedView.where(id: view.id))
    expect(page).to have_css("[data-test='saved-view-apply-#{view.id}']", text: "Aperti")
    expect(page).to have_css("[data-test='saved-view-delete-#{view.id}']")
    expect(page).to have_link("Aperti", href: /status_id/)
  end

  it "il modale riepiloga i filtri correnti e li serializza in hidden field" do
    render_widget(views: SavedView.none,
                  current_filters: { "status_id" => %w[s1 s2], "q" => "login", "evil" => "x" })
    expect(page).to have_css("[data-test='saved-view-summary']")
    expect(page).to have_text("login")   # q → testo
    expect(page).to have_text("×2")      # multi-select → conteggio
    expect(page).to have_css("input[type=hidden][name='resource_type'][value='tickets']", visible: :all)
    expect(page).to have_css("input[type=hidden][name='status_id[]'][value='s1']", visible: :all)
    expect(page).to have_css("input[type=hidden][name='q'][value='login']", visible: :all)
    # chiave non ammessa scartata dal riepilogo/hidden
    expect(page).not_to have_css("input[name='evil']", visible: :all)
  end

  it "names the grouping and shows the period as is in the summary (CYRA-924)" do
    render_inline(described_class.new(resource_type: "uptime", views: SavedView.none,
                                      index_helper: :member_monitoring_monitors_path,
                                      current_filters: { "view" => "table", "range" => "7d" }))
    summary = page.find("[data-test='saved-view-summary']")
    expect(summary).to have_text(I18n.t("shared.saved_views.view_values.table"))
    expect(summary).to have_text("7d")
    expect(summary).to have_no_text("×1")
  end

  it "asks in the dialog whether to save the filters too, checked by default (CYRA-924)" do
    render_widget(views: SavedView.none)
    box = page.find("[data-test='saved-view-include-filters']", visible: :all)
    expect(box[:type]).to eq("checkbox")
    expect(box[:name]).to eq("include_filters")
    expect(box[:checked]).to be_truthy
    expect(page).to have_css("input[type=hidden][name='include_filters'][value='0']", visible: :all)
    expect(page).to have_text(I18n.t("shared.saved_views.include_filters"))
  end

  # F24: the save dialog opens in the standard modal shell, Save in the header inside the form.
  it "opens the save dialog in the standard modal shell" do
    render_widget(views: SavedView.none)
    dialog = page.find("dialog[data-test='saved-view-modal']", visible: :all)
    expect(dialog[:class]).to include("dark:bg-zinc-950", "rounded-xl")
    expect(dialog).to have_css("form header [data-test='saved-view-save']", visible: :all)
    expect(dialog).to have_css("form [data-test='saved-view-modal-panel'] [data-test='saved-view-name']", visible: :all)
    expect(dialog).to have_css("[data-action='ui--dialog#close']", count: 1, visible: :all)
  end

  it "senza filtri correnti mostra summary_none" do
    render_widget(views: SavedView.none)
    expect(page).to have_css("[data-test='saved-view-summary-none']")
  end

  it "il campo nome nel modale espone un focus ring visibile ad AA (indigo-500 su focus-visible)" do
    render_widget(views: SavedView.none)
    html = page.native.to_html
    expect(html).to include("focus-visible:ring-indigo-500")
    expect(html).not_to include("focus:ring-indigo-100")
  end
end
