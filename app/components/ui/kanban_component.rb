# frozen_string_literal: true

module Ui
  # A board is one panel (T1, K9): the filter bar as its toolbar, the columns side by side below it,
  # scrolling sideways inside the panel. Drag, keyboard and collapse live in the page's Stimulus
  # controller, named by `controller:`; every column is one of its `column` targets.
  class KanbanComponent < BaseComponent
    renders_one :toolbar
    renders_many :columns, ->(**args) { Column.new(controller: @controller, **args) }

    def initialize(controller:, test_id: nil, **options)
      @controller = controller
      @test_id = test_id
      @options = options
    end

    private

    def html_options
      merge_options(base_class: "flex min-h-0 flex-1 flex-col rounded-lg border border-stone-200 dark:border-zinc-800 bg-white dark:bg-zinc-900",
                    test_id: @test_id, options: @options)
    end
  end
end
