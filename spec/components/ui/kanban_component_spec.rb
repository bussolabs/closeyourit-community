# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::KanbanComponent, type: :component do
  def column_args(**overrides)
    { key: "open", label: "Open", color: "amber", total: 5, test_prefix: "board",
      list_id: "board_column_1", count_id: "board_count_1", has_cards: true }.merge(overrides)
  end

  it "is one white panel: toolbar on top, the columns below it (T1, K9)" do
    render_inline(described_class.new(controller: "ticket-board", test_id: "board-panel")) do |board|
      board.with_toolbar { "<form data-test='toolbar'></form>".html_safe }
      board.with_column(**column_args) { "<a data-test='card'>Card</a>".html_safe }
    end

    panel = page.find("div.rounded-lg.border.border-stone-200.bg-white[data-test='board-panel']")
    expect(panel).to have_css("[data-test='toolbar']")
    expect(panel).to have_css("div.overflow-x-auto [data-test='board-column-open'] [data-test='card']")
  end

  # The cards' screen-reader text is absolutely positioned against this area: without the clip it
  # stretched the page below the last card, and the page scrolled over nothing.
  it "clips the column area, so nothing inside it makes the page scroll" do
    render_inline(described_class.new(controller: "ticket-board")) { |board| board.with_column(**column_args) { "" } }

    expect(page).to have_css("div.relative.min-h-0.flex-1.overflow-hidden > div.overflow-x-auto")
  end

  it "draws a light grey column wired to the page controller (K10)" do
    render_inline(described_class.new(controller: "ticket-board")) do |board|
      board.with_column(**column_args(data: { status_id: 1 })) { "" }
    end

    column = page.find("[data-test='board-column-open']")
    expect(column[:class]).to include("bg-stone-50")
    expect(column["data-ticket-board-target"]).to eq("column")
    expect(column["data-status-id"]).to eq("1")
    expect(column["data-collapsed"]).to eq("false")
    expect(page).to have_css("#board_column_1[data-board-list][role='list']")
    expect(page).to have_css("button[data-test='board-collapse-open'][data-action='ticket-board#toggleCollapse']")
    expect(page).to have_css("button[data-test='board-expand-open'][data-action='ticket-board#toggleCollapse']")
  end

  it "keeps the board tight, so a column shows more cards (K15)" do
    render_inline(described_class.new(controller: "ticket-board")) do |board|
      board.with_column(**column_args(data: { status_id: 1 })) { "" }
    end

    expect(page.find("[data-test='board-column-open']")[:class]).to include("w-68")
    expect(page).to have_css("#board_column_1.space-y-1\\.5")
    expect(page).to have_css("div.flex.h-full.gap-2")
  end

  it "counts the total when no search is on" do
    render_inline(described_class.new(controller: "ticket-board")) { |board| board.with_column(**column_args) { "" } }

    expect(page.find("#board_count_1[data-test='board-count-open']").text).to eq("5")
    expect(page).to have_no_css("[data-board-total]")
  end

  it "counts found / total while a search is on (K11)" do
    render_inline(described_class.new(controller: "ticket-board")) do |board|
      board.with_column(**column_args(found: 1)) { "" }
    end

    expect(page.find("[data-test='board-count-open']").text).to eq("1")
    expect(page.find("[data-test='board-column-open'] .font-mono", match: :first).text.squish).to eq("1 / 5")
    expect(page).to have_css("[data-board-total]", text: "5", count: 2)
  end

  it "collapses a column on its own without marking it as the person's choice (K12)" do
    render_inline(described_class.new(controller: "ticket-board")) do |board|
      board.with_column(**column_args(found: 0, has_cards: false, auto_collapsed: true)) { "" }
    end

    column = page.find("[data-test='board-column-open']")
    expect(column["data-collapsed"]).to eq("true")
    expect(column["data-auto-collapsed"]).to eq("true")
  end

  it "shows the empty body only when the column has no card (K14)" do
    render_inline(described_class.new(controller: "ticket-board")) do |board|
      board.with_column(**column_args(key: "full")) do |column|
        column.with_empty { "<p data-test='empty-full'>Nothing</p>".html_safe }
        "<a>Card</a>".html_safe
      end
      board.with_column(**column_args(key: "none", has_cards: false)) do |column|
        column.with_empty { "<p data-test='empty-none'>Nothing</p>".html_safe }
      end
    end

    expect(page).to have_css("[data-board-empty][hidden] [data-test='empty-full']", visible: :all)
    expect(page).to have_css("[data-board-empty]:not([hidden]) [data-test='empty-none']")
  end

  it "puts the note under the head and the footer under the cards" do
    render_inline(described_class.new(controller: "ticket-board")) do |board|
      board.with_column(**column_args) do |column|
        column.with_note { "<p data-test='note'>Last 14 days</p>".html_safe }
        column.with_footer { "<a data-test='more'>Show more</a>".html_safe }
        ""
      end
    end

    expect(page).to have_css("[data-test='board-column-open'] [data-test='note']")
    expect(page).to have_css("[data-test='board-column-open'] [data-test='more']")
  end
end
