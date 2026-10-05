# frozen_string_literal: true

module Ui
  # One group of cards: a heading (mark, name, Mono count, actions) over the grid. Without `title:`
  # there is no heading, which is the "None" grouping (D20). `muted:` greys the name (Ungrouped).
  class CardGridComponent::Group < BaseComponent
    # While one card is hovered or focused, the others fade (D21): the cards must be direct <a> children.
    # D25 — as many columns as fit, no gap: the cards are cells split by hairlines.
    GRID = "grid grid-cols-[repeat(auto-fill,minmax(240px,1fr))] -mr-px -mb-px " \
           "[&:has(>a:hover)>a:not(:hover)]:opacity-[.55] [&:has(>a:focus-visible)>a:not(:focus-visible)]:opacity-[.55]"

    renders_one :mark
    renders_one :actions

    def initialize(title: nil, href: nil, count_label: nil, muted: false, test_id: nil, title_test_id: nil)
      @title = title
      @href = href
      @count_label = count_label
      @muted = muted
      @test_id = test_id
      @title_test_id = title_test_id
    end
  end
end
