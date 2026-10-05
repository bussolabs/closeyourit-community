# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::RowMenuComponent, type: :component do
  it "rende details/summary/pannello con le voci + wiring Stimulus ui--row-menu" do
    render_inline(described_class.new(test_id: "row-menu-1")) do
      "<a data-test=\"edit\">Edit</a>".html_safe
    end

    expect(page).to have_css("details.relative[data-controller~='ui--row-menu']")
    expect(page).to have_css("summary[data-test='row-menu-1'][data-ui--row-menu-target='trigger']")
    expect(page).to have_css("details summary svg[data-icon='ellipsis']")
    # Pannello: fallback CSS absolute (il controller lo passa a position:fixed a runtime).
    # Dentro un <details> collassato → hidden per Capybara (come i system spec).
    expect(page).to have_css("div.absolute.right-0.top-9.z-30[data-ui--row-menu-target='panel'] a[data-test='edit']", text: "Edit", visible: :all)
  end

  describe ".item_class" do
    it "default → voce neutra" do
      expect(described_class.item_class(:default)).to include("text-zinc-900", "hover:bg-stone-50")
    end

    it "danger → voce distruttiva rossa" do
      expect(described_class.item_class(:danger)).to include("text-red-600", "hover:bg-red-50")
    end

    it "solleva ArgumentError su variante sconosciuta" do
      expect { described_class.item_class(:nope) }.to raise_error(ArgumentError)
    end
  end

  it "il trigger ha nome accessibile (aria-label) e segnala il popup (aria-haspopup)" do
    render_inline(described_class.new) { "voci" }
    html = page.native.to_html
    expect(html).to include("aria-label").and include('aria-haspopup="menu"')
    expect(page).to have_css("summary[aria-label='#{I18n.t('shared.actions.row_menu')}'][aria-haspopup='menu']")
  end

  it "aria_label esplicito sovrascrive il default i18n" do
    render_inline(described_class.new(aria_label: "Azioni ticket #42")) { "voci" }
    expect(page).to have_css("summary[aria-label='Azioni ticket #42']")
  end

  it "l'icona ellipsis è decorativa (aria-hidden)" do
    render_inline(described_class.new) { "voci" }
    expect(page).to have_css("summary svg[data-icon='ellipsis'][aria-hidden='true']")
  end

  it "icon: sostituisce l'ellipsis, per distinguere due menu affiancati" do
    render_inline(described_class.new(icon: "git-branch")) { "voci" }
    expect(page).to have_css("summary svg[data-icon='git-branch'][aria-hidden='true']")
    expect(page).to have_no_css("summary svg[data-icon='ellipsis']")
  end

  it "il trigger ha il focus ring (focus-visible, prima mancante — T3)" do
    render_inline(described_class.new) { "voci" }
    expect(page).to have_css(
      "summary.focus-visible\\:outline-none.focus-visible\\:ring-2.focus-visible\\:ring-indigo-500"
    )
  end

  describe "width del pannello" do
    it "default md → w-44" do
      render_inline(described_class.new) { "x" }
      expect(page).to have_css("div.absolute.w-44", visible: :all)
    end

    it "lg → w-48" do
      render_inline(described_class.new(width: :lg)) { "x" }
      expect(page).to have_css("div.absolute.w-48", visible: :all)
    end

    it "solleva ArgumentError su width sconosciuta" do
      expect { described_class.new(width: :xl) }.to raise_error(ArgumentError)
    end
  end
end
