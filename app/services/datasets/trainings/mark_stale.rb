# frozen_string_literal: true

module Datasets
  module Trainings
    # Chiude gli addestramenti ORFANI (CYRA-791): il processo che li eseguiva è morto senza passare da
    # nessun `rescue` — SIGKILL, deploy interrotto, worker riavviato — e il record è rimasto
    # `pending`/`running`. Nessuno lo riportava a un esito: la guardia anti-doppione di
    # Datasets::Trainings::Start guarda esattamente quei due stati e rifiutava OGNI avvio successivo
    # sullo stesso insieme di dati, per sempre, senza un rimedio dalla pagina né da terminale.
    #
    # Chi è morto e chi sta lavorando si distinguono per il BATTITO (Training#beat!, scritto da Run a
    # ogni giro): oltre TRAINING_STALE_AFTER di silenzio l'esecuzione non c'è più. La soglia è la
    # stessa durata del semaforo di concorrenza di TrainJob e non un numero a parte — oltre quella
    # Solid Queue avrebbe comunque lasciato partire un secondo lavoro sullo stesso dataset, quindi qui
    # non si apre nessuna finestra di doppio costo che non fosse già aperta.
    #
    # NON rilancia niente: l'addestramento diventa `failed` con un motivo leggibile e il nuovo avvio
    # resta una decisione di chi paga le chiamate AI.
    class MarkStale < ApplicationService
      def initialize(dataset: nil, now: Time.current, after: Datasets::Constants::TRAINING_STALE_AFTER)
        @dataset = dataset
        @now = now
        @after = after
      end

      def call
        marked = 0
        # Gli id si raccolgono FUORI dalla transazione: la lista è uno snapshot e ogni riga viene poi
        # rivalidata sotto lock, perché un addestramento può concludersi tra lo snapshot e adesso.
        scope.stale_at(@now, after: @after).pluck(:id).each { |id| marked += 1 if mark_one(id) }
        Result.ok(marked)
      end

      private

      def scope = @dataset ? @dataset.trainings : Datasets::Training.all

      def mark_one(id)
        ApplicationRecord.transaction do
          training = Datasets::Training.lock.find_by(id: id)
          # Rivalutazione sotto lock: il battito può essere arrivato ora, o il lavoro può aver appena
          # finito. Dichiarare interrotto un addestramento vivo è peggio del problema di partenza —
          # sbloccherebbe un secondo avvio mentre il primo sta ancora pagando chiamate AI.
          next false unless training&.stale?(now: @now, after: @after)

          training.finish_err!(code: "R500-DATASET-001", message: I18n.t("datasets.errors.interrupted"))
          true
        end
      end
    end
  end
end
