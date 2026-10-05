# frozen_string_literal: true

module Datasets
  module Predictions
    # Applica il prompt ottimizzato di un training agli input di una riga nuova (purpose=prediction) →
    # valori predetti per ogni target, salvati sul record Datasets::Prediction. Stato sul record (la UI
    # lo polla). Eseguito da Datasets::PredictJob.
    class Predict < ApplicationService
      def initialize(prediction:, client: nil)
        @prediction = prediction
        @dataset = prediction.dataset
        @training = prediction.training
        @client = client
      end

      def call
        # Idempotenza: SolidQueue è at-least-once. Una riconsegna non deve rifare la chiamata LLM né
        # riportare a running una predizione già done/failed.
        return Result.ok(@prediction) unless @prediction.status_pending?
        return fail_no_training if @training.nil? || @training.system_prompt.blank?

        @prediction.update!(status: :running)
        result = Datasets::Ai::Predict.call(
          system_prompt: @training.system_prompt, row: @prediction.input_row,
          input_columns: @dataset.input_columns, target_columns: @dataset.target_columns,
          client: @client
        )
        return propagate(result) if result.err?

        @prediction.finish_ok!(predicted_values: result.value)
        Result.ok(@prediction)
      rescue StandardError => e
        Rails.logger.error("Datasets::Predictions::Predict failed prediction=#{@prediction.id}: #{e.class} #{e.message}")
        @prediction.finish_err!(code: "R500-SYSTEM-001", message: I18n.t("datasets.errors.internal"))
        Result.err(AppError.new(I18n.t("datasets.errors.internal"), code: "R500-SYSTEM-001", status: :internal_server_error))
      end

      private

      def propagate(result)
        @prediction.finish_err!(code: result.error.code, message: result.error.message)
        result
      end

      def fail_no_training
        @prediction.finish_err!(code: "R422-DATASET-005", message: I18n.t("datasets.errors.no_training"))
        Result.err(AppError.new(I18n.t("datasets.errors.no_training"), code: "R422-DATASET-005"))
      end
    end
  end
end
