# frozen_string_literal: true

module Errors
  # CYRA-1241: backfill one-shot dell'elenco delle persone viste (Errors::GroupUser) per i gruppi
  # PRE-esistenti, dalle occorrenze ancora conservate. Senza, chi ha eventi recenti verrebbe contato
  # di nuovo appena la potatura li cancella. Idempotente (ON CONFLICT DO NOTHING): rilanciarlo, o
  # farlo girare mentre l'ingest aggiunge persone, non duplica niente.
  #
  # A blocchi di gruppi, ognuno nella propria breve transazione: nessun lock sui gruppi, l'ingest
  # continua mentre gira. Legge dall'indice (group_id, user_hash) delle occorrenze.
  # Lancio manuale al deploy:
  #   bin/rails runner 'Errors::BackfillGroupUsersJob.perform_later'
  class BackfillGroupUsersJob < ApplicationJob
    queue_as :batch

    BATCH_SIZE = 500

    def perform
      Errors::Group.in_batches(of: BATCH_SIZE) do |batch|
        ids = batch.pluck(:id)
        Errors::GroupUser.connection.exec_update(Errors::GroupUser.sanitize_sql_array([ <<~SQL.squish, ids ]))
          INSERT INTO errors_group_users (id, group_id, user_hash, created_at)
          SELECT gen_random_uuid(), e.group_id, e.user_hash, MIN(e.created_at)
          FROM errors_events e
          WHERE e.group_id IN (?) AND e.user_hash IS NOT NULL
          GROUP BY e.group_id, e.user_hash
          ON CONFLICT (group_id, user_hash) DO NOTHING
        SQL
      end
    end
  end
end
