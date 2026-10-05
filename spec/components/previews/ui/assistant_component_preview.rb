# frozen_string_literal: true

module Ui
  class AssistantComponentPreview < ViewComponent::Preview
    # Il trigger è inline sotto md e FAB flottante da md in su.
    def default
      render(Ui::AssistantComponent.new)
    end
  end
end
