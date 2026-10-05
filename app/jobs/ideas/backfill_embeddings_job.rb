# frozen_string_literal: true

module Ideas
  # Backfill/re-embed dell'intero parco idee (coda :batch). Idempotente: accoda EmbedIdeaJob
  # solo per le idee col checksum stale (mai embeddate, testo cambiato senza job riuscito, o
  # EMBEDDING_VERSION bumpata). Lancio manuale:
  #   bin/rails runner 'Ideas::BackfillEmbeddingsJob.perform_later'
  # Gira anche in recurring.yml come i gemelli ticket/errori/conoscenza: l'idempotenza per checksum lo
  # rende sicuro come cron e ripara da sola la finestra di un guasto del servizio embedding.
  class BackfillEmbeddingsJob < ApplicationJob
    queue_as :batch

    def perform
      Ideas::Idea.includes(:project).find_each do |idea|
        next if idea.embedding.present? &&
                idea.embedding_checksum == Ideas::EmbeddingText.checksum(idea: idea)

        Ideas::EmbedIdeaJob.perform_later(idea_id: idea.id)
      end
    end
  end
end
