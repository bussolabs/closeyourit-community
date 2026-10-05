# frozen_string_literal: true

module Datasets
  module Predictions
    # Avvio di una previsione: le condizioni per partire (un addestramento riuscito da cui prendere il
    # prompt, servizio collegato), la scrittura della riga in ingresso e l'accodamento del lavoro.
    # L'esecuzione vera è Datasets::Predictions::Predict, dentro PredictJob.
    #
    # CYRA-647: la regola vive QUI e non nei controller perché i canali sono due (la pagina e la CLI).
    # Il permesso resta al chiamante: è autorizzazione, non dominio.
    class Start < ApplicationService
      def initialize(dataset:, actor:, values:, photos:)
        @dataset = dataset
        @actor = actor
        @values = values
        @photos = photos
      end

      def call
        training = latest_training
        return fail_no_training if training.nil?

        row = save_input_row
        return row if row.err?

        Result.ok(start_prediction(training, row.value))
      end

      private

      def latest_training = @dataset.trainings.status_done.ordered.first

      def save_input_row
        ::Datasets::Rows::Save.call(dataset: @dataset, actor: @actor, purpose: :prediction,
                                    values: @values, photos: @photos)
      end

      # La riga in ingresso e la previsione nascono insieme: se la seconda non parte, la prima non deve
      # restare nel dataset a fare da domanda senza risposta — e nemmeno a gonfiare le righe di
      # inferenza con tentativi che nessuno ha mai eseguito. L'accodamento è dentro la stessa guardia
      # perché una coda non disponibile lascerebbe una previsione ferma su "in attesa" per sempre.
      def start_prediction(training, row)
        prediction = @dataset.predictions.create!(training: training, input_row: row,
                                                  created_by: @actor, status: :pending)
        Datasets::PredictJob.perform_later(prediction)
        prediction
      rescue StandardError
        prediction&.destroy
        row.destroy
        raise
      end

      def fail_no_training
        Result.err(AppError.new(I18n.t("datasets.errors.no_training"), code: "R422-DATASET-005"))
      end
    end
  end
end
