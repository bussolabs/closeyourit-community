# frozen_string_literal: true

module Errors
  # Backfill/re-embed dei gruppi errori (coda :batch). Idempotente via checksum-guard.
  # Lancio manuale:
  #   bin/rails runner 'Errors::BackfillEmbeddingsJob.perform_later'
  # Gira anche in recurring.yml (daily, CYRA-232): l'idempotenza lo rende sicuro come cron e ripara da
  # sola la finestra di un guasto del servizio embedding. EmbeddingText legge solo colonne del gruppo
  # (title/culprit), nessuna associazione → niente N+1, nessun preload necessario.
  class BackfillEmbeddingsJob < ApplicationJob
    queue_as :batch

    def perform
      Errors::Group.includes(:project).find_each do |group|
        next if group.embedding.present? &&
                group.embedding_checksum == Errors::EmbeddingText.checksum(group: group)

        Errors::EmbedGroupJob.perform_later(group_id: group.id)
      end
    end
  end
end
