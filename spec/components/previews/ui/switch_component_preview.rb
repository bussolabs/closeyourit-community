# frozen_string_literal: true

module Ui
  class SwitchComponentPreview < ViewComponent::Preview
    def on
      render(Ui::SwitchComponent.new(
               name: "roadmap_enabled", url: "/projects/1/settings", checked: true, icon: "map",
               label: "Roadmap", hint: "Abilita milestone, board roadmap e ticket feature/improvement.",
               test_id: "switch-on"
             ))
    end

    def off
      render(Ui::SwitchComponent.new(
               name: "quick_bug_report_enabled", url: "/projects/1/settings", checked: false,
               icon: "wand-sparkles", label: "Quick bug report",
               hint: "Assistente AI che struttura una segnalazione da testo libero.", test_id: "switch-off"
             ))
    end

    def without_icon
      render(Ui::SwitchComponent.new(name: "flag", url: "/projects/1/settings", checked: true, label: "Senza icona"))
    end
  end
end
