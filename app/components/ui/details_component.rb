# frozen_string_literal: true

module Ui
  # The Details box on the right of an object page (E1, E2): one label/value row per fact, the value
  # on the right, the label above it on phones. Empty rows and an empty box are not shown (E7).
  class DetailsComponent < BaseComponent
    renders_many :rows, "Ui::DetailsComponent::Row"
    # The quiet created/updated line closing the box (E22).
    renders_one :footer

    def initialize(title:, test_id: nil, **options)
      @title = title
      @test_id = test_id
      @options = options
    end

    # The block fills the slots only when `content` runs, so it runs before counting the rows.
    def render?
      content
      rows.any? { |row| row.content? || row.value? }
    end
  end
end
