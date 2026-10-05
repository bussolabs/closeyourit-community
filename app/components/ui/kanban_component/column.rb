# frozen_string_literal: true

module Ui
  # One board column (K10): light grey, head with state dot, name, count and collapse button; a
  # collapsed column is a vertical bar that opens on click. `found:` is set only while a search is on
  # and turns the count into "found / total" (K11); `auto_collapsed:` is the collapse a search causes,
  # which the page controller must not save as the person's choice (K12).
  class KanbanComponent::Column < BaseComponent
    renders_one :note
    renders_one :empty
    renders_one :footer

    def initialize(controller:, key:, label:, color:, total:, test_prefix:, list_id:, count_id:, has_cards:,
                   found: nil, collapsed: false, auto_collapsed: false, data: {})
      @controller = controller
      @key = key
      @label = label
      @color = color
      @total = total
      @found = found
      @test_prefix = test_prefix
      @list_id = list_id
      @count_id = count_id
      @has_cards = has_cards
      @auto_collapsed = auto_collapsed == true
      @collapsed = collapsed == true || @auto_collapsed
      @data_extra = data
    end

    private

    attr_reader :label, :list_id, :count_id, :has_cards

    def column_data
      data = { test: test_id("column"), "#{@controller}-target": "column", collapsed: @collapsed }
      data[:auto_collapsed] = true if @auto_collapsed
      data.merge(@data_extra)
    end

    def toggle_action = "#{@controller}#toggleCollapse"

    def test_id(part) = "#{@test_prefix}-#{part}-#{@key}"

    def shown_count = @found.nil? ? @total : @found

    def search_on? = !@found.nil?

    def swatch = Ui::Colors.swatch(@color)
  end
end
