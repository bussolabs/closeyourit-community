# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::EntityCardComponent, type: :component do
  def render_card(**options, &block)
    render_inline(described_class.new(href: "/member/projects/1", title: "Storefront", key: "STR",
                                      description: "Public storefront.", test_id: "project-card-1", **options), &block)
  end

  it "is one link with the name, the key in Mono and one grey line (D1, D2, D24)" do
    render_card

    card = page.find("a[href='/member/projects/1'][data-test='project-card-1']")
    expect(card).to have_css("span.font-display", text: "Storefront")
    expect(card).to have_css("span.font-mono", text: "STR")
    expect(card).to have_css("p.text-gray-500", text: "Public storefront.")
  end

  it "is a cell of the grid: right and bottom hairline, no radius, compact (D25)" do
    render_card

    card = page.find("a[data-test='project-card-1']")
    expect(card[:class]).to include("border-r", "border-b", "px-3.5", "py-3")
    expect(card[:class]).not_to include("rounded-lg")
    expect(page).to have_css("span.font-display.text-\\[13\\.5px\\]", text: "Storefront")
  end

  it "tints the cell and lights the name on hover and focus, never with a shadow (D21, A2)" do
    render_card

    card = page.find("a[data-test='project-card-1']")
    expect(card[:class]).to include("hover:bg-indigo-50/60", "dark:hover:bg-indigo-500/15", "focus-visible:bg-indigo-50/60")
    # The group heading row is neutral grey: a grey tint would melt the hovered card into it.
    expect(card[:class]).not_to include("hover:bg-stone-50 ", "dark:hover:bg-zinc-800")
    expect(card[:class]).not_to include("shadow")
    expect(page).to have_css("span.group-hover\\/card\\:text-indigo-600", text: "Storefront")
  end

  it "draws the mark, the meta, the badges and the footer slots" do
    render_card do |card|
      card.with_mark { "<i data-test='mark'></i>".html_safe }
      card.with_meta { "<i data-test='github'></i>".html_safe }
      card.with_badges { "<span data-test='badge'>No errors</span>".html_safe }
      card.with_footer { "<span data-test='todo'>2 to do</span>".html_safe }
    end

    %w[mark github badge todo].each { |id| expect(page).to have_css("[data-test='#{id}']") }
    expect(page).to have_css("div.font-mono [data-test='todo']")
  end

  it "replaces the footer end with the open label on hover" do
    render_card(open_label: "Open project") do |card|
      card.with_footer_end { "v1.2 · 2 days ago" }
    end

    expect(page).to have_css("span.group-hover\\/card\\:hidden", text: "v1.2 · 2 days ago")
    expect(page).to have_css("span.hidden.group-hover\\/card\\:inline", text: "Open project")
  end

  it "shows the open label on the badges row when there is no footer, so hovering adds no row" do
    render_card(open_label: "Open project") do |card|
      card.with_badges { "<span data-test='badge'>No errors</span>".html_safe }
    end

    expect(page).to have_css("div.flex-wrap [data-test='badge'] ~ span.ml-auto.group-hover\\/card\\:inline", text: "Open project")
    expect(page).to have_no_css("div.mt-auto")
  end

  it "leaves out the grey line when there is no description" do
    render_card(description: nil)

    expect(page).to have_no_css("p.text-gray-500")
  end
end
