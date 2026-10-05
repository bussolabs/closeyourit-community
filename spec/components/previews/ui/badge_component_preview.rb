# frozen_string_literal: true

module Ui
  class BadgeComponentPreview < ViewComponent::Preview
    def neutral = render(Ui::BadgeComponent.new(label: "Neutral"))
    def with_dot = render(Ui::BadgeComponent.new(label: "Open", color: :amber, dot: true))
    def pulsing = render(Ui::BadgeComponent.new(label: "In progress", color: :indigo, pulse: true))
    def with_icon = render(Ui::BadgeComponent.new(label: "Owner", color: :indigo, icon: "crown"))
    def small = render(Ui::BadgeComponent.new(label: "Small", color: :violet, size: :sm))

    # Status di default: in_progress/in_review pulsano (animated: true nel DB).
    def status_open = render(Ui::BadgeComponent.new(label: "Open", color: :amber, dot: true))
    def status_in_progress = render(Ui::BadgeComponent.new(label: "In progress", color: :indigo, dot: true, pulse: true))
    def status_in_review = render(Ui::BadgeComponent.new(label: "In review", color: :violet, dot: true, pulse: true))
    def status_resolved = render(Ui::BadgeComponent.new(label: "Resolved", color: :emerald, dot: true))
    def status_closed = render(Ui::BadgeComponent.new(label: "Closed", color: :gray, dot: true))
  end
end
