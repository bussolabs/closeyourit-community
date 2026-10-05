# frozen_string_literal: true

module Ui
  class SelectComponentPreview < ViewComponent::Preview
    PROJECTS = [ [ "Storefront", "1" ], [ "Payments API", "2" ], [ "Dashboard", "3" ] ].freeze
    STATUSES = [ [ "Open", "1", "amber" ], [ "In progress", "2", "indigo" ], [ "Closed", "3", "gray" ] ].freeze

    def default
      render(Ui::SelectComponent.new(name: "project_id", label: "Project", options: PROJECTS,
                                     placeholder: "Select a project…", include_blank: true))
    end

    def required_with_selection
      render(Ui::SelectComponent.new(name: "status_id", label: "Status", options: STATUSES,
                                     selected: "1", required: true))
    end

    # Filtro: summary → il trigger mostra "Status: Open, In progress" (placeholder = noun, niente label block).
    def multiple_filter
      render(Ui::SelectComponent.new(name: "status_id", options: STATUSES,
                                     selected: %w[1 2], multiple: true, summary: true, placeholder: "Status"))
    end

    # Filtro con 3+ selezioni: cap a 2 + contatore → "Project: Storefront, Payments API +1".
    def multiple_filter_overflow
      render(Ui::SelectComponent.new(name: "project_id", options: PROJECTS,
                                     selected: %w[1 2 3], multiple: true, summary: true, placeholder: "Project"))
    end

    def with_error
      render(Ui::SelectComponent.new(name: "project_id", label: "Project", options: PROJECTS,
                                     error: "Required"))
    end
  end
end
