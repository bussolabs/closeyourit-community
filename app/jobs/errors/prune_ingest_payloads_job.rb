# frozen_string_literal: true

module Errors
  # Raccoglie le staging d'ingest (Errors::IngestPayload) orfane: il job di ingest cancella la propria
  # riga appena l'evento è persistito, quindi qui restano solo i payload dei job scartati dopo i retry.
  #
  # NON è una potatura per età dei dati (quelli li rimuove subito il job): è la raccolta degli orfani,
  # tenuta LARGA di proposito per non cancellare mai il payload di un job ancora in coda. I retry si
  # esauriscono in minuti e un backlog d'ingest si smaltisce in ore; una riga più vecchia della finestra
  # (allineata a Jobs::PruneFailedExecutionsJob) ha quindi un job o già girato o morto da un pezzo — un
  # job ancora pending dopo una settimana implicherebbe un worker fermo da giorni, già in allarme.
  class PruneIngestPayloadsJob < ApplicationJob
    queue_as :batch

    RETENTION = 7.days

    def perform
      Errors::IngestPayload.where(created_at: ..RETENTION.ago).in_batches.delete_all
    end
  end
end
