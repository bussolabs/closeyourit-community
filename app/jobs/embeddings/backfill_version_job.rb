# frozen_string_literal: true

module Embeddings
  # Backfill one-shot di `embedding_version` sulle righe GIÀ embeddate prima di CYRA-168 (hanno
  # vettore + checksum ma `embedding_version` nil). Il sistema è a UNA sola versione viva
  # (Ai::Constants::EMBEDDING_VERSION): quelle righe sono di quella versione, quindi le stampiamo —
  # senza, il filtro `current_embedding` della ricerca semantica le escluderebbe TUTTE e la ricerca
  # tornerebbe vuota fino al re-embed completo.
  #
  # Bulk `update_all` (un UPDATE per tabella, nessun callback/validazione), IDEMPOTENTE: il filtro
  # `embedding_version: nil` rende ogni ri-esecuzione un no-op. Va lanciato UNA volta al deploy, come
  # gli altri backfill:
  #   bin/rails runner 'Embeddings::BackfillVersionJob.perform_later'
  #
  # Distinto dai `*::BackfillEmbeddingsJob`: quelli ri-embeddano SOLO le righe col checksum stale e
  # NON popolano `embedding_version` sulle righe già correnti → serve questo backfill dedicato.
  class BackfillVersionJob < ApplicationJob
    queue_as :batch

    def perform
      [ Errors::Group, Knowledge::Page, Ticketing::Ticket ].each do |model|
        model.where.not(embedding: nil)
             .where(embedding_version: nil)
             .update_all(embedding_version: Ai::Configuration.current.embedding_version)
      end
    end
  end
end
