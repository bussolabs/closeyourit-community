# frozen_string_literal: true

module Ui
  class RowActionsFormComponentPreview < ViewComponent::Preview
    # Il modulo unico della pagina (nascosto) più due righe che lo puntano: nessuna delle due porta
    # un modulo suo.
    def default
      render_with_template(template: "ui/row_actions_form_component_preview/default")
    end
  end
end
