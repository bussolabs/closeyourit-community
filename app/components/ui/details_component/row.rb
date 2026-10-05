# frozen_string_literal: true

module Ui
  # One row of the Details box: a plain `value:` or a block for a composed one (a link, badges).
  # `action:` is a small link that sits next to the label, such as "Manage tokens".
  class DetailsComponent::Row < BaseComponent
    def initialize(label:, value: nil, action: nil, test_id: nil, **options)
      @label = label
      @value = value
      @action = action
      @test_id = test_id
      @options = options
    end

    def value? = @value.present?

    def render? = value? || content?

    private

    def html_options
      merge_options(base_class: "grid grid-cols-1 gap-1 px-4 py-2.5 sm:flex sm:items-center sm:justify-between sm:gap-3",
                    test_id: @test_id, options: @options)
    end
  end
end
