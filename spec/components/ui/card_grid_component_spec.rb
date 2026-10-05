# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::CardGridComponent, type: :component do
  it "is one panel: toolbar, groups, sections to set up and Show more all inside it (T1, D19)" do
    render_inline(described_class.new(test_id: "projects-cards")) do |grid|
      grid.with_toolbar { "<form data-test='toolbar'></form>".html_safe }
      grid.with_group(title: "Storefront Suite") { "<a data-test='card'>Card</a>".html_safe }
      grid.with_more(href: "/more", test_id: "more")
      grid.with_setup_item(label: "Mobile", test_id: "setup") { "" }
    end

    panel = page.find("div.rounded-lg.border.border-stone-200.bg-white[data-test='projects-cards']")
    %w[toolbar card more setup].each { |id| expect(panel).to have_css("[data-test='#{id}']") }
    expect(page).to have_css("div.border-t [data-test='more']")
  end

  it "splits the groups by a hairline (T3)" do
    render_inline(described_class.new) do |grid|
      grid.with_group(title: "One") { "" }
      grid.with_group(title: "Two") { "" }
    end

    expect(page).to have_css("div.divide-y > section", count: 2)
  end

  it "joins the cards into cells split only by hairlines, as many per row as fit (D25)" do
    render_inline(described_class.new) { |grid| grid.with_group(title: "One") { "" } }

    grid = page.find("div.grid")
    expect(grid[:class]).to include("grid-cols-[repeat(auto-fill,minmax(240px,1fr))]", "-mr-px", "-mb-px")
    expect(grid[:class]).not_to include("gap-4")
    expect(page).to have_css("div.overflow-hidden > div.grid")
    expect(page).to have_css("section > div.border-b h2", text: "One")
  end

  it "heads each group with its mark, name, count and actions (D20)" do
    render_inline(described_class.new) do |grid|
      grid.with_group(title: "Storefront Suite", href: "/member/groups/1", count_label: "2 projects",
                      test_id: "projects-group-1", title_test_id: "projects-group-link-1") do |group|
        group.with_mark { "<i data-test='group-mark'></i>".html_safe }
        group.with_actions { "<a data-test='manage'>Manage group</a>".html_safe }
        "<a data-test='card'>Card</a>".html_safe
      end
    end

    section = page.find("section[data-test='projects-group-1']")
    expect(section).to have_css("h2 a[href='/member/groups/1'][data-test='projects-group-link-1']", text: "Storefront Suite")
    expect(section).to have_css("span.font-mono", text: "2 projects")
    expect(section).to have_css("[data-test='group-mark']")
    expect(section).to have_css("[data-test='manage']")
    expect(section).to have_css("div.grid [data-test='card']")
  end

  it "draws a group without heading when grouping is off" do
    render_inline(described_class.new) do |grid|
      grid.with_group(test_id: "projects-all") { "<a data-test='card'>Card</a>".html_safe }
    end

    expect(page).to have_no_css("section[data-test='projects-all'] h2")
    expect(page).to have_css("section[data-test='projects-all'] div.grid [data-test='card']")
  end

  it "fades the other cards of a group while one is hovered or focused (D21)" do
    render_inline(described_class.new) { |grid| grid.with_group { "" } }

    expect(page.find("div.grid")[:class]).to include("[&:has(>a:hover)>a:not(:hover)]:opacity-[.55]",
                                                    "[&:has(>a:focus-visible)>a:not(:focus-visible)]:opacity-[.55]")
  end

  it "offers Show more after the cards (D23)" do
    render_inline(described_class.new) do |grid|
      grid.with_group { "" }
      grid.with_more(href: "/member/projects?limit=24", test_id: "projects-more")
    end

    expect(page).to have_css("a[href='/member/projects?limit=24'][data-test='projects-more']", text: I18n.t("ui.card_grid.show_more"))
  end

  it "says how many cards the next click adds when it is told (D23)" do
    render_inline(described_class.new) do |grid|
      grid.with_group { "" }
      grid.with_more(href: "/member/projects?limit=24", count: 5, test_id: "projects-more")
    end

    expect(page).to have_css("[data-test='projects-more']", text: I18n.t("ui.card_grid.show_more_count", count: 5))
  end

  it "lists the sections to set up at the bottom, small and dashed (D11)" do
    render_inline(described_class.new(test_id: "projects-cards")) do |grid|
      grid.with_setup_item(label: "Mobile", href: "/member/groups/2", test_id: "projects-empty-group-2") { "<i data-test='mark'></i>".html_safe }
    end

    setup = page.find("[data-test='projects-cards-setup']")
    expect(setup).to have_text(I18n.t("ui.card_grid.to_set_up"))
    expect(setup).to have_css("a.border-dashed[href='/member/groups/2'][data-test='projects-empty-group-2']", text: "Mobile")
  end

  it "shows the no-results slot in place of the groups (G4)" do
    render_inline(described_class.new) do |grid|
      grid.with_no_results { "<div data-test='no-match'></div>".html_safe }
      grid.with_group { "<a data-test='card'></a>".html_safe }
    end

    expect(page).to have_css("[data-test='no-match']")
    expect(page).to have_no_css("[data-test='card']")
  end
end
