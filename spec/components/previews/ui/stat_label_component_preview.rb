# frozen_string_literal: true

module Ui
  class StatLabelComponentPreview < ViewComponent::Preview
    def neutral = render(Ui::StatLabelComponent.new(label: "Tickets", value: 12))
    def open_count = render(Ui::StatLabelComponent.new(label: "Open", value: 6, value_color: :amber))
    def in_progress = render(Ui::StatLabelComponent.new(label: "In progress", value: 3, value_color: :indigo))
    def resolved = render(Ui::StatLabelComponent.new(label: "Resolved", value: 3, value_color: :emerald))

    # Riga di conteggi tipica di un header (composizione in un flex wrapper).
    def header_row
      render_with_template(template: "ui/stat_label_component_preview/header_row")
    end
  end
end
