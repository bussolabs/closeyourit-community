# frozen_string_literal: true

module Knowledge
  # Backfill/re-embed dell'intero parco pagine KB (coda :batch). Idempotente:
  # accoda EmbedPageJob solo per le pagine col checksum stale (mai embeddate, testo cambiato
  # senza job riuscito, o EMBEDDING_VERSION bumpata). Lancio manuale:
  #   bin/rails runner 'Knowledge::BackfillEmbeddingsJob.perform_later'
  # Gira anche in recurring.yml (daily, CYRA-232): l'idempotenza per checksum lo rende sicuro come cron e
  # ripara da sola la finestra di un guasto del servizio embedding.
  class BackfillEmbeddingsJob < ApplicationJob
    queue_as :batch

    def perform
      Knowledge::Page.find_each do |page|
        next if page.embedding.present? &&
                page.embedding_checksum == Knowledge::EmbeddingText.checksum(page: page)

        Knowledge::EmbedPageJob.perform_later(page_id: page.id)
      end
    end
  end
end
