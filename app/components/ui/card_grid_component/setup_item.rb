# frozen_string_literal: true

module Ui
  # A section not used yet, at the bottom of a card page: small and dashed (D11). The block is its mark.
  class CardGridComponent::SetupItem < BaseComponent
    CLASS = "inline-flex items-center gap-1.5 rounded-md border border-dashed border-stone-300 dark:border-zinc-700 px-2.5 py-1 " \
            "text-gray-600 dark:text-zinc-400 hover:border-stone-400 dark:hover:border-zinc-600 hover:text-indigo-600 dark:hover:text-indigo-400"

    def initialize(label:, href: nil, test_id: nil)
      @label = label
      @href = href
      @test_id = test_id
    end

    def call
      content_tag(@href ? :a : :span, safe_join([ content, @label ].compact), href: @href, class: CLASS, data: { test: @test_id })
    end
  end
end
