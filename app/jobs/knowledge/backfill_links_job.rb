# frozen_string_literal: true

module Knowledge
  # Ricostruisce il grafo dei wikilink su tutto il parco pagine (coda :batch). Serve in due
  # momenti: al primo deploy (le pagine scritte prima della funzionalità non hanno collegamenti) e
  # ogni volta che serve riconciliare i wikilink rimasti irrisolti — Links::Sync congela il
  # collegamento per id al salvataggio, quindi un `[[Titolo]]` scritto PRIMA che quella pagina
  # esistesse resta testo finché la sorgente non viene risalvata (o finché non gira questo job).
  #
  # Idempotente: Sync riscrive per intero i collegamenti uscenti di ogni pagina. Lancio manuale:
  #   bin/rails runner 'Knowledge::BackfillLinksJob.perform_later'
  # NON va in recurring.yml: è bootstrap/riconciliazione, non un cron.
  class BackfillLinksJob < ApplicationJob
    queue_as :batch

    def perform
      # Sync risolve i wikilink per organization_id (colonna della pagina): nessuna associazione da precaricare.
      Knowledge::Page.find_each do |page|
        Knowledge::Links::Sync.call(page: page)
      end
    end
  end
end
