# frozen_string_literal: true

module Ui
  class AuditMetaComponentPreview < ViewComponent::Preview
    # Created + Updated con autori (caso tipico ticket/progetto).
    def default
      render(Ui::AuditMetaComponent.new(
               created_at: Time.zone.local(2026, 3, 12, 14, 32), created_by: "Marco Rossi",
               updated_at: Time.zone.local(2026, 3, 20, 9, 50), updated_by: "Olivia Lane"
             ))
    end

    # Con link "View activity history" (slot action).
    def with_history
      render(Ui::AuditMetaComponent.new(
               created_at: Time.zone.local(2026, 3, 12, 14, 32), created_by: "Marco Rossi",
               updated_at: Time.zone.local(2026, 3, 20, 9, 50), updated_by: "Olivia Lane"
             )) do |c|
        c.with_action do
          tag.a(class: "inline-flex items-center gap-1.5 text-[12px] font-medium text-indigo-600 hover:text-indigo-700", href: "#") do
            safe_join([ c.render(Ui::IconComponent.new(name: "history", class: "text-[11px]")), I18n.t("ui.audit.view_history") ])
          end
        end
      end
    end

    # Solo creazione (nessun aggiornamento ancora).
    def created_only
      render(Ui::AuditMetaComponent.new(created_at: Time.zone.local(2026, 3, 12, 14, 32), created_by: "Marco Rossi"))
    end

    # Entità di sistema: date senza autore umano.
    def system_entity
      render(Ui::AuditMetaComponent.new(
               created_at: Time.zone.local(2026, 3, 12, 14, 32),
               updated_at: Time.zone.local(2026, 3, 20, 9, 50)
             ))
    end
  end
end
