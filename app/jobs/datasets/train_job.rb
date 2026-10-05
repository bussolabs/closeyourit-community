# frozen_string_literal: true

module Datasets
  # Esegue il training in background (coda :ai): il loop di prompt-engineering chiama il gateway LLM più
  # volte (~30s l'una) → fuori dal thread Puma. Lo stato vive sul record Datasets::Training (la UI lo
  # polla). Niente retry: Run incapsula gli errori in finish_err!; un'eccezione inattesa marca failed
  # (ritentare ripagherebbe chiamate LLM per un esito già mostrato come fallito).
  class TrainJob < ApplicationJob
    queue_as :ai

    # Un solo training per dataset alla volta (CYRA-246): difesa in profondità oltre al rifiuto nel
    # controller. Protegge dal doppio-enqueue (due click ravvicinati, retry) e dalla consegna
    # at-least-once di Solid Queue. Chiave sul dataset → training di dataset diversi restano paralleli.
    # duration esplicita a 2h: il training può durare fino a ~un'ora e il semaforo di Solid Queue scade
    # dopo soli 3 minuti di default — scaduto verrebbe potato e sbloccherebbe un secondo job in parallelo.
    # A fine job il semaforo è rilasciato subito (non aspetta la scadenza), quindi la durata larga non
    # ritarda i training successivi legittimi: copre solo la finestra del training ancora vivo.
    # Il numero arriva da Constants::TRAINING_STALE_AFTER (CYRA-791) perché è LO STESSO: oltre quella
    # finestra il semaforo è scaduto e la coda non protegge più dal doppione, quindi è anche il punto
    # oltre cui un training senza battito viene dichiarato interrotto. Due valori scritti a mano che
    # si allontanano riaprono, da un lato il doppio costo, dall'altro il dataset bloccato per sempre.
    limits_concurrency to: 1, key: ->(training) { training.dataset_id },
                       duration: Datasets::Constants::TRAINING_STALE_AFTER

    def perform(training)
      Datasets::Trainings::Run.call(training: training)
    rescue StandardError => e
      Rails.logger.error("Datasets::TrainJob failed training=#{training.id}: #{e.class} #{e.message}")
      training.finish_err!(code: "R500-SYSTEM-001", message: I18n.t("datasets.errors.internal"))
    end
  end
end
