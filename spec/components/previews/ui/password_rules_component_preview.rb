# frozen_string_literal: true

module Ui
  class PasswordRulesComponentPreview < ViewComponent::Preview
    def default = render(Ui::PasswordRulesComponent.new)
  end
end
