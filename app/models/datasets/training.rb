# frozen_string_literal: true

module Datasets
  # Un training = una esecuzione che produce un prompt ottimizzato (system_prompt) + metriche di
  # accuratezza sul dataset. Artefatto PERSISTENTE (a differenza di Ai::Request, effimero) e insieme
  # record di stato del job async: pending → running → done/failed (vedi Datasets::TrainJob).
  class Training < ApplicationRecord
    belongs_to :dataset,
               class_name: "Datasets::Dataset",
               inverse_of: :trainings
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true

    has_many :predictions,
             class_name: "Datasets::Prediction",
             foreign_key: :training_id,
             inverse_of: :training,
             dependent: :nullify

    enum :status, { pending: 0, running: 1, done: 2, failed: 3 }, prefix: :status

    scope :ordered, -> { order(created_at: :desc) }
    scope :unfinished, -> { where(status: %i[pending running]) }

    # CYRA-791 — gli addestramenti senza segni di vita da oltre `after`. Il segno di vita è il battito
    # di chi sta eseguendo; per chi non è mai partito (pending) è la creazione, perché un battito non
    # c'è mai stato. COALESCE in SQL e non due condizioni: la regola è una sola e deve restare una sola
    # riga anche nel piano di query.
    scope :stale_at, lambda { |now, after: Datasets::Constants::TRAINING_STALE_AFTER|
      unfinished.where("COALESCE(heartbeat_at, created_at) < ?", now - after)
    }

    # Gli esiti sono TERMINALI (CYRA-791): un addestramento già chiuso non torna indietro. Serve al
    # recupero — se il giro lo ha dichiarato interrotto e il processo che lo eseguiva risorge, la sua
    # conclusione tardiva non deve riscrivere l'esito già mostrato né far partire un secondo avviso.
    # La domanda «è già chiuso?» si fa SOTTO LOCK, non sull'istanza in memoria: chi arriva tardi ha in
    # mano una copia vecchia — è stato via ore — e leggendo quella troverebbe sempre `running`.
    def finish_ok!(system_prompt:, config: {}, metrics: {})
      return false unless write_outcome { update!(status: :done, system_prompt:, config:, metrics:) }

      notify_result(:dataset_training_completed)
    end

    def finish_err!(code:, message:)
      return false unless write_outcome { update!(status: :failed, error_code: code, error_message: message) }

      notify_result(:dataset_training_failed)
    end

    def finished? = status_done? || status_failed?

    # Segno di vita di chi sta eseguendo (CYRA-791): senza, un addestramento lento e uno morto col
    # processo sono indistinguibili. `touch` e non `update!`: è un battito, non una modifica di stato.
    def beat! = touch(:heartbeat_at)

    def last_signal_at = heartbeat_at || created_at

    def stale?(now: Time.current, after: Datasets::Constants::TRAINING_STALE_AFTER)
      return false if finished?

      last_signal_at < now - after
    end

    private

    # Scrive l'esito solo se non ce n'è già uno (CYRA-791). `with_lock` ricarica la riga e la blocca:
    # da lì la lettura è quella vera, e nessuno può infilare un esito diverso nel frattempo. L'avviso
    # resta FUORI: si annuncia un esito committato, mai uno ancora dentro una transazione.
    def write_outcome
      with_lock do
        next false if finished?

        yield
        true
      end
    end

    # CYRA-147: all'esito del training avvisa chi vede il progetto del dataset via la pipeline rule-based.
    # Questo è l'imbuto unico (Run#finish_ok!/err! + il rescue di TrainJob passano tutti di qui), così
    # nessun percorso di esito resta scoperto. Enqueue DOPO l'update committato — siamo già dentro il job
    # di training e la coda vive su un DB separato. Senza una regola attiva nell'org, Evaluate è un no-op.
    def notify_result(event_type)
      Alerting::EvaluateJob.perform_later(
        event_type: event_type.to_s, subject_type: "Datasets::Training", subject_id: id,
        project_id: dataset.project_id
      )
    end
  end
end
