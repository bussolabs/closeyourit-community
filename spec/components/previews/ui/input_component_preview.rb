# frozen_string_literal: true

module Ui
  class InputComponentPreview < ViewComponent::Preview
    def multiline = render(Ui::InputComponent.new(name: "memory", label: "Memoria", type: "textarea", value: "Conserva le decisioni approvate.", rows: 5))
    def default = render(Ui::InputComponent.new(name: "name", label: "Nome", placeholder: "Mario Rossi"))
    def required = render(Ui::InputComponent.new(name: "email", label: "Email", type: "email", required: true))
    def with_hint = render(Ui::InputComponent.new(name: "slug", label: "Slug", hint: "Usato nell'URL dell'organizzazione"))
    def with_error = render(Ui::InputComponent.new(name: "email", label: "Email", value: "non-valida", error: "Email non valida"))
  end
end
