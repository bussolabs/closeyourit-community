# frozen_string_literal: true

module Ui
  class ChangelogReleaseComponentPreview < ViewComponent::Preview
    def default
      render(Ui::ChangelogReleaseComponent.new(release: sample_release))
    end

    private

    # Release fittizia SOLO per il catalogo (eccezione mock consentita nei preview).
    def sample_release
      Changelog::Release.new(
        version: "0.0.52",
        date: "2026-07-01",
        sections: [
          { label: "Added", items: [
            "**Revisore del ticket.** Notifica quando il ticket entra in revisione.",
            "Board Kanban con drag-drop."
          ] },
          { label: "Fixed", items: [ "Allineati i test di presenza per-viewer." ] }
        ]
      )
    end
  end
end
