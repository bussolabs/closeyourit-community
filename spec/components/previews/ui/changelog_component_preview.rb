# frozen_string_literal: true

module Ui
  class ChangelogComponentPreview < ViewComponent::Preview
    # Footer sidebar con trigger versione + modale (clicca "v0.0.52" per aprire il <dialog>).
    def default
      render(Ui::ChangelogComponent.new(current: sample.first, releases: sample))
    end

    # Nessuna release nota (CHANGELOG assente): il trigger mostra "dev".
    def empty
      render(Ui::ChangelogComponent.new(current: nil, releases: []))
    end

    private

    # Release fittizie SOLO per il catalogo (eccezione mock consentita nei preview).
    def sample
      [
        Changelog::Release.new(
          version: "0.0.52", date: "2026-07-01",
          sections: [ { label: "Added", items: [ "**Revisore del ticket.** Notifica quando entra in revisione." ] } ]
        ),
        Changelog::Release.new(
          version: "0.0.51", date: "2026-06-30",
          sections: [ { label: "Changed", items: [ "Presenza online ristretta al contesto condiviso." ] } ]
        )
      ]
    end
  end
end
