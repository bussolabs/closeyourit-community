# frozen_string_literal: true

module Datasets
  # Giro periodico sugli addestramenti rimasti orfani di un processo morto (CYRA-791): li porta a un
  # esito leggibile invece di lasciarli "in corso" per sempre. Idempotente — un secondo giro non trova
  # più niente da chiudere, perché guarda solo pending/running.
  #
  # È la rete, non l'unica strada: nello scenario del ticket il motore dei lavori è proprio quello che
  # è morto, quindi questo giro può non partire. Il recupero che l'utente vede vive dentro
  # Datasets::Trainings::Start, sulla richiesta di un nuovo avvio.
  class MarkStaleTrainingsJob < ApplicationJob
    queue_as :maintenance

    def perform
      marked = Datasets::Trainings::MarkStale.call.value.to_i
      # Il silenzio è il vizio che questo giro corregge: quanti addestramenti sono morti senza dirlo
      # deve leggersi nei log, non scoprirsi da una pagina ferma.
      Rails.logger.info("Datasets::MarkStaleTrainingsJob: #{marked} addestramenti interrotti chiusi") if marked.positive?
      marked
    end
  end
end
