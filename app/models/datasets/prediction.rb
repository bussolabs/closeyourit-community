# frozen_string_literal: true

module Datasets
  # Una predizione = l'applicazione del prompt di un training a una riga di input (purpose=prediction)
  # per ottenere il result predetto. Record di stato del job async (Datasets::PredictJob).
  class Prediction < ApplicationRecord
    belongs_to :dataset,
               class_name: "Datasets::Dataset",
               inverse_of: :predictions
    belongs_to :training,
               class_name: "Datasets::Training",
               optional: true,
               inverse_of: :predictions
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true
    belongs_to :input_row,
               class_name: "Datasets::Row"

    enum :status, { pending: 0, running: 1, done: 2, failed: 3 }, prefix: :status

    validate :input_row_and_training_same_dataset

    scope :ordered, -> { order(created_at: :desc) }

    def finish_ok!(predicted_values:)
      update!(status: :done, predicted_values:)
    end

    def finish_err!(code:, message:)
      update!(status: :failed, error_code: code, error_message: message)
    end

    private

    # Tenant integrity (difesa in profondità, come Cell#row_and_column_same_dataset): la riga di input e
    # il training devono appartenere allo stesso dataset della predizione.
    def input_row_and_training_same_dataset
      errors.add(:input_row, :invalid) if input_row.present? && input_row.dataset_id != dataset_id
      errors.add(:training, :invalid) if training.present? && training.dataset_id != dataset_id
    end
  end
end
