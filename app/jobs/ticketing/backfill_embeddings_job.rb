# frozen_string_literal: true

module Ticketing
  # Backfill/re-embed dell'intero parco ticket (coda :batch). Idempotente:
  # accoda EmbedTicketJob solo per i ticket col checksum stale (mai embeddati, testo cambiato
  # senza job riuscito, o EMBEDDING_VERSION bumpata). Lancio manuale:
  #   bin/rails runner 'Ticketing::BackfillEmbeddingsJob.perform_later'
  # Gira anche in recurring.yml (daily, CYRA-232): l'idempotenza per checksum lo rende sicuro come cron e
  # ripara da sola la finestra di un guasto del servizio embedding.
  class BackfillEmbeddingsJob < ApplicationJob
    queue_as :batch

    def perform
      # includes(:scenarios): il checksum di ogni ticket embeddato legge ticket.scenarios — senza preload
      # è un N+1 sull'intero storico, ora che il job gira daily (CYRA-232).
      Ticketing::Ticket.includes(:scenarios, :project).find_each do |ticket|
        next if ticket.embedding.present? &&
                ticket.embedding_checksum == Ticketing::EmbeddingText.checksum(ticket: ticket)

        Ticketing::EmbedTicketJob.perform_later(ticket_id: ticket.id)
      end
    end
  end
end
