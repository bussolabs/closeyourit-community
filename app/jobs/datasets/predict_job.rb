# frozen_string_literal: true

module Datasets
  # Esegue una predizione in background (coda :ai): la chiamata LLM vision (~lunga) fuori dal thread
  # Puma. Stato sul record Datasets::Prediction (la UI lo polla). Niente retry (ripagherebbe l'LLM);
  # un'eccezione inattesa marca failed.
  class PredictJob < ApplicationJob
    queue_as :ai

    # Una sola predizione per dataset alla volta (CYRA-246): come TrainJob, protegge da doppio-enqueue e
    # retry sulla corsia AI a slot unico. Chiave sul dataset, semaforo distinto da quello del training.
    # duration 15m: una predizione può superare i 3 minuti di default (polling + timeout HTTP); senza,
    # il semaforo scadrebbe e ne lascerebbe partire un'altra in parallelo sullo stesso dataset.
    limits_concurrency to: 1, key: ->(prediction) { prediction.dataset_id }, duration: 15.minutes

    def perform(prediction)
      Datasets::Predictions::Predict.call(prediction: prediction)
    rescue StandardError => e
      Rails.logger.error("Datasets::PredictJob failed prediction=#{prediction.id}: #{e.class} #{e.message}")
      prediction.finish_err!(code: "R500-SYSTEM-001", message: I18n.t("datasets.errors.internal"))
    end
  end
end
