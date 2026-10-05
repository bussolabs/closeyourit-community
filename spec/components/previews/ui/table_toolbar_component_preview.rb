# frozen_string_literal: true

module Ui
  class TableToolbarComponentPreview < ViewComponent::Preview
    # Search + filtri a chip (nascosti finché non attivati dal menu "Filtri") + conteggio.
    # Con JS si vede il flusso reale: menu → chip → auto-submit.
    def with_filters; end

    # Solo search + conteggio (tabelle senza filtri multi, es. projects).
    def search_only; end
  end
end
