# frozen_string_literal: true

module Ui
  # A page of cards is one panel (T1, D19): the filter bar as its toolbar, the groups of cards split by a
  # hairline, the sections not used yet (D11), "Show more" as its footer. With grouping off, one group
  # without a heading. The cards are items of the panel, like table rows (A12).
  class CardGridComponent < BaseComponent
    renders_one :toolbar
    renders_one :no_results
    renders_many :groups, "Ui::CardGridComponent::Group"
    # `count` = how many cards the next click adds: the button then says the number (D23).
    renders_one :more, lambda { |href:, test_id: nil, count: nil|
      label = count ? t("ui.card_grid.show_more_count", count: count) : t("ui.card_grid.show_more")
      ButtonComponent.new(label: label, href: href, variant: :secondary_muted, size: :sm, test_id: test_id)
    }
    renders_many :setup_items, "Ui::CardGridComponent::SetupItem"

    def initialize(test_id: nil, setup_test_id: nil, **options)
      @test_id = test_id
      @setup_test_id = setup_test_id
      @options = options
    end

    private

    def html_options = merge_options(base_class: "rounded-lg border border-stone-200 dark:border-zinc-800 bg-white dark:bg-zinc-900", test_id: @test_id, options: @options)

    def setup_test_id = @setup_test_id || (@test_id && "#{@test_id}-setup")
  end
end
