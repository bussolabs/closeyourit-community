# frozen_string_literal: true

module Ui
  class ButtonGroupComponentPreview < ViewComponent::Preview
    # Coppia di decisione della home: due pieni attaccati, nessuna cornice.
    def decision
      render(Ui::ButtonGroupComponent.new) do |group|
        group.with_button(variant: :success, size: :sm, icon: "check", icon_only: true, label: "Approva")
        group.with_button(variant: :danger, size: :sm, icon: "x", icon_only: true, label: "Rifiuta")
      end
    end

    # Segmented control: figli trasparenti, cornice e separatori passati dal caller.
    def segmented
      render(Ui::ButtonGroupComponent.new(class: "border border-stone-200 bg-white divide-x divide-stone-200")) do |group|
        group.with_button(variant: :tinted, size: :sm, icon: "table-cells-large", label: "Card")
        group.with_button(variant: :ghost, size: :sm, icon: "menu", label: "Tabella")
      end
    end
  end
end
