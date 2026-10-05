# frozen_string_literal: true

module Ui
  class ButtonComponentPreview < ViewComponent::Preview
    def primary = render(Ui::ButtonComponent.new(label: "Primary", icon: "plus"))
    def secondary = render(Ui::ButtonComponent.new(label: "Secondary", variant: :secondary))
    def ghost = render(Ui::ButtonComponent.new(label: "Ghost", variant: :ghost))
    def tinted = render(Ui::ButtonComponent.new(label: "Tinted", variant: :tinted))
    def danger = render(Ui::ButtonComponent.new(label: "Elimina", variant: :danger, icon: "trash"))
    def small = render(Ui::ButtonComponent.new(label: "Small", size: :sm))
    def large = render(Ui::ButtonComponent.new(label: "Large", size: :lg))
    def as_link = render(Ui::ButtonComponent.new(label: "Vai", href: "#", variant: :secondary))
    def disabled = render(Ui::ButtonComponent.new(label: "Disabled", disabled: true))
    def success = render(Ui::ButtonComponent.new(label: "Approva", variant: :success, icon: "check"))
    def success_outline = render(Ui::ButtonComponent.new(label: "Approva", variant: :success_outline, icon: "check"))

    # Quadrato con la sola icona: la label resta obbligatoria e diventa aria-label + title.
    def icon_only = render(Ui::ButtonComponent.new(label: "Approva", variant: :success, icon: "check", icon_only: true))
  end
end
