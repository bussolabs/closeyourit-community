# frozen_string_literal: true

module Knowledge
  # Ripristina una versione precedente come nuova live: delega a UpdatePage col contenuto dello
  # snapshot → crea una NUOVA versione (append-only, la storia non si riscrive mai), la rende live
  # e ri-embedda. Ripristinare la versione già live = no-op idempotente (nessun saved_changes →
  # nessuna nuova versione, nessun re-embed). Ritorna il Result di UpdatePage.
  class RestoreVersion < ApplicationService
    def initialize(page:, version:, actor:)
      @page = page
      @version = version
      @actor = actor
    end

    def call
      Knowledge::UpdatePage.call(
        page: @page,
        params: { title: @version.title, body: @version.body, tech_spec: @version.tech_spec, kind: @version.kind },
        actor: @actor
      )
    end
  end
end
