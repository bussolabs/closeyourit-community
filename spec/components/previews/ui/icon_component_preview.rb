# frozen_string_literal: true

module Ui
  class IconComponentPreview < ViewComponent::Preview
    def default = render(Ui::IconComponent.new(name: "ticket", class: "text-[14px] text-gray-500 dark:text-zinc-400"))
    def colored = render(Ui::IconComponent.new(name: "triangle-alert", class: "text-[14px] text-amber-600 dark:text-amber-400"))
    def labelled = render(Ui::IconComponent.new(name: "lock", label: "Segreto protetto", class: "text-[14px] text-zinc-900 dark:text-zinc-100"))
    def fixed_width = render(Ui::IconComponent.new(name: "house", class: "w-[1.25em] text-[14px] text-gray-400 dark:text-zinc-500"))
    def spinning = render(Ui::IconComponent.new(name: "loader-circle", class: "animate-spin text-[14px] text-indigo-600 dark:text-indigo-400"))
  end
end
