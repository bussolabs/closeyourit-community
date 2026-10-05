# frozen_string_literal: true

module Ui
  # Card DS: superficie flat, bordo 1px, niente shadow. Slot header/footer opzionali.
  class CardComponent < BaseComponent
    renders_one :header
    renders_one :footer

    def initialize(highlighted: false, test_id: nil, **options)
      @highlighted = highlighted
      @test_id = test_id
      @options = options
    end

    private

    def html_options
      border = @highlighted ? "border-indigo-600 dark:border-indigo-400" : "border-stone-200 dark:border-zinc-800"
      merge_options(base_class: "rounded-lg border #{border} bg-white dark:bg-zinc-900", test_id: @test_id, options: @options)
    end
  end
end
