# frozen_string_literal: true

module Ui
  class RowMenuComponentPreview < ViewComponent::Preview
    def default
      render(Ui::RowMenuComponent.new(test_id: "row-menu-preview")) do
        safe_join([
          tag.a("Edit", href: "#", class: Ui::RowMenuComponent.item_class(:default)),
          tag.div(class: "my-1 border-t border-stone-200"),
          tag.a("Delete", href: "#", class: Ui::RowMenuComponent.item_class(:danger))
        ])
      end
    end
  end
end
