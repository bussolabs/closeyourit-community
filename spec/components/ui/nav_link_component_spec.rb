# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::NavLinkComponent, type: :component do
  it "renders a link with its icon and label" do
    render_inline(described_class.new(label: "Tickets", path: "/member/tickets", icon: "ticket", test_id: "nav-tickets"))

    link = page.find("a[data-test='nav-tickets']")
    expect(link[:href]).to eq("/member/tickets")
    expect(link).to have_css("svg[data-icon='ticket'][aria-hidden='true']")
    expect(link).to have_text("Tickets")
  end

  it "marks the active row with the indigo tint and aria-current page" do
    render_inline(described_class.new(label: "Tickets", path: "/t", icon: "ticket", active: true))

    expect(page).to have_css("a.bg-indigo-50.text-indigo-700[aria-current='page']")
    expect(page).to have_css("svg[data-icon='ticket'].text-indigo-500")
  end

  it "shows a detail line under the label" do
    render_inline(described_class.new(label: "Researcher", path: "/c", detail: "Found three sources", test_id: "nav-dot"))

    expect(page).to have_css("a[data-test='nav-dot'] span", text: "Researcher")
    expect(page).to have_css("a[data-test='nav-dot'] [data-test='nav-detail']", text: "Found three sources")
  end

  it "leaves an idle row without aria-current" do
    render_inline(described_class.new(label: "Tickets", path: "/t", icon: "ticket"))

    expect(page).to have_css("a.text-gray-600:not([aria-current])")
    expect(page).to have_css("svg[data-icon='ticket'].text-gray-400")
  end

  it "uses the given aria-current value, for a group whose area holds the page" do
    render_inline(described_class.new(label: "Product", path: "/p", active: true, current: "true"))

    expect(page).to have_css("a[aria-current='true']")
  end

  it "keeps the label for screen readers in compact mode and exposes it for the tooltip" do
    render_inline(described_class.new(label: "Home", path: "/"))

    expect(page).to have_css("a[data-nav-label='Home'] span.md\\:group-data-\\[compact\\]\\/sidebar\\:sr-only", text: "Home")
  end

  it "renders leaves indented and without the compact hooks" do
    render_inline(described_class.new(label: "Ideas", path: "/i", size: :leaf))

    expect(page).to have_css("a.pl-10:not([data-nav-label])", text: "Ideas")
  end

  it "renders footer rows at the small footer text size, keeping the compact hooks" do
    render_inline(described_class.new(label: "Guides", path: "/g", icon: "book", size: :footer))

    expect(page).to have_css("a.text-\\[12px\\][data-nav-label='Guides']:not(.text-\\[13px\\])")
    expect(page).to have_css("svg[data-icon='book'].text-\\[13px\\]")
  end

  it "renders trailing content after the label" do
    render_inline(described_class.new(label: "Approvals", path: "/a")) { "3" }

    expect(page.find("a").text).to end_with("3")
  end

  it "turns trailing content into a dot in compact mode when asked" do
    render_inline(described_class.new(label: "Chat", path: "/c", test_id: "dot", dot: true)) { "2" }

    expect(page).to have_css("a.relative[data-test='dot'] span.md\\:group-data-\\[compact\\]\\/sidebar\\:absolute", text: "2")
  end

  it "keeps the trailing content hidden in compact mode by default" do
    render_inline(described_class.new(label: "Chat", path: "/c")) { "2" }

    expect(page).to have_css("a:not(.relative) span.md\\:group-data-\\[compact\\]\\/sidebar\\:hidden", text: "2")
  end

  it "renders flyout rows unindented and without the compact hooks" do
    render_inline(described_class.new(label: "Errors", path: "/e", size: :flyout))

    expect(page).to have_css("a:not(.pl-10):not([data-nav-label])", text: "Errors")
  end

  it "lets the caller override the icon colour" do
    render_inline(described_class.new(label: "Valhalla", path: "/v", icon: "crown", icon_class: "text-amber-500",
                                      size: :account))

    expect(page).to have_css("svg[data-icon='crown'].text-amber-500.text-\\[13px\\]")
  end

  describe "preview" do
    Ui::NavLinkComponentPreview.examples.each do |example|
      it "renders the '#{example}' example without errors" do
        expect { render_preview(example) }.not_to raise_error
      end
    end
  end
end
