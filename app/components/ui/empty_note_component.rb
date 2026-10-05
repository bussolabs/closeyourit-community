# frozen_string_literal: true

module Ui
  # CYRA-910 — the one-line empty inside a panel or a section ("no comments yet"): one look
  # everywhere. A page with nothing to show uses EmptyStateComponent instead.
  # `inset` adds the padding of a list row, for panels whose body has none.
  class EmptyNoteComponent < BaseComponent
    def initialize(text:, hint: nil, inset: false, test_id: nil, **options)
      @text = text
      @hint = hint
      @inset = inset
      @test_id = test_id
      @options = options
    end

    private

    attr_reader :text, :hint

    def wrapper_options
      merge_options(base_class: "text-[12.5px] text-gray-500 dark:text-zinc-400#{" px-4 py-6" if @inset}",
                    test_id: @test_id, options: @options)
    end
  end
end
