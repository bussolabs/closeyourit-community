# frozen_string_literal: true

module Ui
  # One card of a card page (D1–D4, D24): a single link with the mark, the name, the key in Mono on the
  # right, one grey line, the badges and a footer of Mono counters. Hover and focus light the border
  # and the name, never a shadow (D21, A2); `open_label:` takes the footer end's place meanwhile, or sits at
  # the end of the badges row when there is no footer, so hovering never adds a row.
  # D25 — a compact cell of the grid: its right and bottom hairline divide it from its neighbours.
  class EntityCardComponent < BaseComponent
    LIT = "transition duration-150 motion-reduce:transition-none"

    renders_one :mark
    renders_one :meta
    renders_one :badges
    renders_one :footer
    renders_one :footer_end

    def initialize(href:, title:, key: nil, description: nil, open_label: nil, open_hint_test_id: nil, test_id: nil, **options)
      @href = href
      @title = title
      @key = key
      @description = description
      @open_label = open_label
      @open_hint_test_id = open_hint_test_id
      @test_id = test_id
      @options = options
    end

    private

    def html_options
      merge_options(base_class: "group/card flex flex-col gap-2 border-r border-b border-stone-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 px-3.5 py-3 #{LIT} " \
                                "hover:bg-indigo-50/60 dark:hover:bg-indigo-500/15 focus-visible:bg-indigo-50/60 dark:focus-visible:bg-indigo-500/15 focus-visible:outline-none " \
                                "focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-indigo-500 dark:focus-visible:ring-indigo-400",
                    test_id: @test_id, options: @options)
    end

    def footer_row? = footer? || footer_end? || (@open_label.present? && !hint_on_badges?)

    def hint_on_badges? = @open_label.present? && badges? && !footer? && !footer_end?

    def open_hint
      tag.span(@open_label, class: "hidden ml-auto font-sans text-[11px] font-medium text-indigo-600 dark:text-indigo-400 " \
                                   "group-hover/card:inline group-focus-visible/card:inline",
                            data: { test: open_hint_test_id })
    end

    def open_hint_test_id = @open_hint_test_id || (@test_id && "#{@test_id}-open-hint")
  end
end
