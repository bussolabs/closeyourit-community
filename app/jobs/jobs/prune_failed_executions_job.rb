# frozen_string_literal: true

module Jobs
  # Retention delle esecuzioni fallite di Solid Queue.
  #
  # `clear_solid_queue_finished_jobs` (recurring.yml) pota i job FINITI. Un job fallito non finisce
  # mai: resta in `solid_queue_failed_executions` col padre a `finished_at` nullo, per sempre. Senza
  # questa potatura ogni incidente passato continua a contare come guasto presente — a fine luglio
  # 2026 la lista mostrava 12.080 falliti, di cui 11.318 erano un bug di Uptime::CheckJob chiuso il
  # 7 luglio: il 94% del rumore era archeologia.
  class PruneFailedExecutionsJob < ApplicationJob
    queue_as :batch

    # Sette giorni: la finestra in cui un fallito serve ancora a qualcosa, cioè capire cos'è successo
    # ed eventualmente rilanciare. Oltre, nessuno ritenta più un job di una settimana fa — e tenerli
    # non aggiunge storia, aggiunge rumore che nasconde i guasti veri.
    RETENTION = 7.days

    def perform
      # `discard_all_in_batches` cancella l'esecuzione E il `SolidQueue::Job` padre. Con un
      # `delete_all` sulla sola esecuzione resterebbero job orfani mai finiti: lo stesso sintomo di
      # prima, con un'altra faccia.
      SolidQueue::FailedExecution.where(created_at: ..RETENTION.ago).discard_all_in_batches
    end
  end
end
